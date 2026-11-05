import Foundation

enum RelaySettingsJourney {
    static let instruction = """
    For settings requests, read relay_get_settings first. State the exact target (Relay on This Mac), public setting name, current value and proposed value before relay_update_settings. Use the returned instance and revision, one stable request_id and existing consent/action policy. Never change Miko authority or monitoring policy yourself. A successful write requires a verified settings_receipt and resulting read; read settings again and compare the requested values before claiming completion. A conflict or uncertain reply requires inspection, never a silent retry with a new ID. Native Settings remains available when a control is unsupported or Miko is unavailable. Secret values belong only in native destination-bound secure entry, never chat or tool arguments.
    """
    static let commonKeys: Set<String> = ["font_family", "font_size", "terminal_padding", "cursor_blink",
        "palette", "compact_interface", "hide_sidebar_fullscreen", "artifact_previews", "artifact_presentation",
        "intelligence_enabled", "intelligence_summaries", "intelligence_search", "relayd_auto_update",
        "automatic_agent_maintenance", "haiku_pane_health", "assistant_hotkey_enabled"]
}
