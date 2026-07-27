//! Machine provenance for a results file.
//!
//! A benchmark record is worthless if it cannot say which machine produced it.
//! Every field here is derived from the running host — nothing is hardcoded,
//! because the original `machine: "mac"` literal silently mislabelled the first
//! Windows run as a Mac.
//!
//! All values are sanitized to a single line: these come from shelling out, and
//! a stray newline would corrupt both the printed header and the JSON record.

/// Collapse command/env output to one clean line, or `None` if it carries nothing.
fn clean(s: &str) -> Option<String> {
    let one = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.is_empty() { None } else { Some(one) }
}

fn cmd(program: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(program).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    clean(&String::from_utf8_lossy(&out.stdout))
}

/// Only the Windows paths read provenance from the environment.
#[cfg(target_os = "windows")]
fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().as_deref().and_then(clean)
}

/// `reg query ... /v NAME` prints `    NAME    REG_SZ    the value`; the value is
/// everything after the type token and may itself contain spaces.
#[cfg(target_os = "windows")]
fn reg_value(key: &str, name: &str) -> Option<String> {
    let raw = cmd("reg", &["query", key, "/v", name])?;
    let (_, after) = raw.split_once("REG_SZ")?;
    clean(after)
}

/// Which box is this — the field that distinguishes one results file from another.
pub fn host_name() -> String {
    #[cfg(target_os = "windows")]
    let found = env("COMPUTERNAME");
    #[cfg(not(target_os = "windows"))]
    let found = cmd("hostname", &["-s"]).or_else(|| cmd("hostname", &[]));

    found.unwrap_or_else(|| "unknown-host".to_string())
}

/// CPU brand string. This benchmark turns out to be single-thread CPU bound, so
/// this is the load-bearing hardware field, not a footnote.
pub fn cpu_brand() -> String {
    #[cfg(target_os = "macos")]
    let found = cmd("sysctl", &["-n", "machdep.cpu.brand_string"]);

    #[cfg(target_os = "windows")]
    let found = reg_value(
        r"HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0",
        "ProcessorNameString",
    )
    .or_else(|| env("PROCESSOR_IDENTIFIER"));

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let found = std::fs::read_to_string("/proc/cpuinfo").ok().and_then(|txt| {
        txt.lines()
            .find(|l| l.starts_with("model name"))
            .and_then(|l| l.split_once(':'))
            .and_then(|(_, v)| clean(v))
    });

    found.unwrap_or_else(|| "unknown-cpu".to_string())
}

/// Assemble the Windows OS label from raw registry values.
///
/// `ProductName` still reads "Windows 10 ..." on Windows 11 — Microsoft never
/// updated it — so the build number is the only reliable discriminator: 22000 is
/// the first Windows 11 build. Pure so it can be tested without a registry.
// Only called on Windows, but kept unconditional so its version logic is tested
// on every platform rather than only where it ships.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
fn windows_product_label(
    product_name: &str,
    build: Option<u32>,
    display_version: Option<&str>,
) -> String {
    let mut label = product_name.to_string();
    if let Some(b) = build {
        if b >= 22000 && label.contains("Windows 10") {
            label = label.replace("Windows 10", "Windows 11");
        }
    }
    match (display_version, build) {
        (Some(v), Some(b)) => format!("{label} {v} (build {b})"),
        (Some(v), None) => format!("{label} {v}"),
        (None, Some(b)) => format!("{label} (build {b})"),
        (None, None) => label,
    }
}

/// OS name and version.
pub fn os_string() -> String {
    #[cfg(target_os = "macos")]
    let found = cmd("sw_vers", &["-productVersion"]).map(|v| format!("macOS {v}"));

    #[cfg(target_os = "windows")]
    let found = {
        const CV: &str = r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        reg_value(CV, "ProductName").map(|name| {
            windows_product_label(
                &name,
                reg_value(CV, "CurrentBuild").and_then(|b| b.parse().ok()),
                reg_value(CV, "DisplayVersion").as_deref(),
            )
        })
    };

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let found: Option<String> = None;

    found.unwrap_or_else(|| std::env::consts::OS.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bug this module exists to prevent: a hardcoded machine name. Each
    /// field must actually resolve on the host running the test.
    #[test]
    fn provenance_fields_resolve() {
        assert_ne!(host_name(), "unknown-host", "host name did not resolve");
        assert_ne!(cpu_brand(), "unknown-cpu", "cpu brand did not resolve");
        assert!(!os_string().is_empty());
    }

    /// These are shelled out, so a newline or tab would corrupt the header and
    /// the JSON. Every field must be exactly one clean line.
    #[test]
    fn provenance_fields_are_single_line() {
        for (field, value) in
            [("host", host_name()), ("cpu", cpu_brand()), ("os", os_string())]
        {
            assert!(
                !value.contains('\n') && !value.contains('\r') && !value.contains('\t'),
                "{field} is not a single clean line: {value:?}"
            );
            assert_eq!(value.trim(), value, "{field} has edge whitespace: {value:?}");
        }
    }

    #[test]
    fn clean_collapses_and_rejects_blank() {
        assert_eq!(clean("  Apple M5 Pro \n").as_deref(), Some("Apple M5 Pro"));
        assert_eq!(clean("a\t\tb").as_deref(), Some("a b"));
        assert_eq!(clean("   \n\t "), None);
        assert_eq!(clean(""), None);
    }

    /// kenai is build 26200 but its registry `ProductName` says "Windows 10 Home".
    /// The build number is the only truthful discriminator.
    #[test]
    fn windows_11_is_not_reported_as_windows_10() {
        assert_eq!(
            windows_product_label("Windows 10 Home", Some(26200), Some("25H2")),
            "Windows 11 Home 25H2 (build 26200)"
        );
        assert_eq!(
            windows_product_label("Windows 10 Pro", Some(19045), Some("22H2")),
            "Windows 10 Pro 22H2 (build 19045)"
        );
        // 22000 is the first Windows 11 build — the boundary itself must flip.
        assert!(windows_product_label("Windows 10 Home", Some(22000), None).contains("Windows 11"));
        assert!(windows_product_label("Windows 10 Home", Some(21999), None).contains("Windows 10"));
    }

    /// Missing registry values must degrade, never fabricate or panic.
    #[test]
    fn windows_label_tolerates_missing_values() {
        assert_eq!(windows_product_label("Windows 11 Pro", None, None), "Windows 11 Pro");
        assert_eq!(
            windows_product_label("Windows 11 Pro", None, Some("24H2")),
            "Windows 11 Pro 24H2"
        );
        // An already-correct name is never rewritten to "Windows 11 11".
        assert_eq!(
            windows_product_label("Windows 11 Home", Some(26200), None),
            "Windows 11 Home (build 26200)"
        );
    }

    /// The CPU brand is reported as the platform gives it, and platforms disagree
    /// about naming; assert only that it names the actual vendor of this host.
    #[test]
    fn cpu_brand_names_a_known_vendor() {
        let brand = cpu_brand().to_lowercase();
        assert!(
            ["apple", "intel", "amd", "ryzen", "qualcomm", "arm"]
                .iter()
                .any(|v| brand.contains(v)),
            "unrecognized CPU brand: {brand:?}"
        );
    }
}
