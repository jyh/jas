//! Panel menu item types.

/// A menu item in a panel's hamburger menu.
#[derive(Debug, Clone, PartialEq)]
pub enum PanelMenuItem {
    /// A plain action: label, command string, optional shortcut hint.
    Action {
        label: &'static str,
        command: &'static str,
        shortcut: &'static str,
    },
    /// A toggle (checkbox) item.
    Toggle {
        label: &'static str,
        command: &'static str,
    },
    /// A radio-group item; items sharing the same `group` are mutually exclusive.
    Radio {
        label: &'static str,
        command: &'static str,
        group: &'static str,
    },
    /// Horizontal separator line.
    Separator,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_item_construction() {
        let item = PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        };
        assert_eq!(item, PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        });
    }

    #[test]
    fn toggle_item_construction() {
        let item = PanelMenuItem::Toggle {
            label: "Show Options",
            command: "toggle_options",
        };
        assert!(matches!(item, PanelMenuItem::Toggle { .. }));
    }

    #[test]
    fn radio_item_construction() {
        let item = PanelMenuItem::Radio {
            label: "RGB",
            command: "set_rgb",
            group: "color_mode",
        };
        assert!(matches!(item, PanelMenuItem::Radio { group: "color_mode", .. }));
    }

    #[test]
    fn separator_equality() {
        assert_eq!(PanelMenuItem::Separator, PanelMenuItem::Separator);
    }
}
