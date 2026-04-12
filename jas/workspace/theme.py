"""Centralized appearance theming for the vector illustration application."""

from dataclasses import dataclass


@dataclass
class Theme:
    window_bg: str
    pane_bg: str
    pane_bg_dark: str
    title_bar_bg: str
    title_bar_text: str
    border: str
    text: str
    text_dim: str
    text_body: str
    text_hint: str
    text_button: str
    tab_active: str
    tab_inactive: str
    button_checked: str
    accent: str


@dataclass
class AppearanceEntry:
    name: str
    label: str


PREDEFINED_APPEARANCES = [
    AppearanceEntry("dark_gray", "Dark Gray"),
    AppearanceEntry("medium_gray", "Medium Gray"),
    AppearanceEntry("light_gray", "Light Gray"),
]

DEFAULT_APPEARANCE_NAME = "dark_gray"

DARK_GRAY = Theme(
    window_bg="#2e2e2e", pane_bg="#3c3c3c", pane_bg_dark="#333333",
    title_bar_bg="#2a2a2a", title_bar_text="#d9d9d9", border="#555555",
    text="#cccccc", text_dim="#999999", text_body="#aaaaaa",
    text_hint="#777777", text_button="#888888",
    tab_active="#4a4a4a", tab_inactive="#353535", button_checked="#505050",
    accent="#4a90d9",
)

MEDIUM_GRAY = Theme(
    window_bg="#484848", pane_bg="#565656", pane_bg_dark="#4d4d4d",
    title_bar_bg="#404040", title_bar_text="#e0e0e0", border="#6a6a6a",
    text="#dddddd", text_dim="#aaaaaa", text_body="#bbbbbb",
    text_hint="#888888", text_button="#999999",
    tab_active="#606060", tab_inactive="#505050", button_checked="#686868",
    accent="#5a9ee6",
)

LIGHT_GRAY = Theme(
    window_bg="#ececec", pane_bg="#f0f0f0", pane_bg_dark="#e6e6e6",
    title_bar_bg="#e0e0e0", title_bar_text="#1d1d1f", border="#d1d1d1",
    text="#1d1d1f", text_dim="#86868b", text_body="#3d3d3f",
    text_hint="#aeaeb2", text_button="#6e6e73",
    tab_active="#ffffff", tab_inactive="#e8e8e8", button_checked="#d4d4d8",
    accent="#007aff",
)


def resolve_appearance(name: str) -> Theme:
    if name == "medium_gray":
        return MEDIUM_GRAY
    elif name == "light_gray":
        return LIGHT_GRAY
    return DARK_GRAY
