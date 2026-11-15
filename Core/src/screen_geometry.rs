use crate::layout::Rect;
use serde::{Deserialize, Serialize};

/// Convert Cocoa's bottom-left global coordinates into Accessibility's
/// top-left coordinates. The primary screen's top edge is the AX origin.
pub fn accessibility_frame(visible: Rect, primary_top: f64) -> Rect {
    Rect::new(
        visible.min_x(),
        primary_top - visible.max_y(),
        visible.w,
        visible.h,
    )
}

/// Computes an off-screen corner origin in Accessibility coordinates that leaves
/// 1 pixel of the window inside `screen` without spilling onto adjacent displays.
pub fn parked_window_origin(
    window_w: f64,
    window_h: f64,
    screen: Rect,
    all_screens: &[Rect],
) -> (f64, f64) {
    let w = window_w.max(1.0);
    let h = window_h.max(1.0);
    let others: Vec<&Rect> = all_screens.iter().filter(|&&s| s != screen).collect();

    let candidates: [((f64, f64), Rect); 4] = [
        // Bottom-right corner (extends right and down)
        (
            (screen.max_x() - 1.0, screen.max_y() - 1.0),
            Rect::new(screen.max_x(), screen.max_y() - 40.0, w, h + 40.0),
        ),
        // Bottom-left corner (extends left and down)
        (
            (screen.min_x() - w + 1.0, screen.max_y() - 1.0),
            Rect::new(screen.min_x() - w, screen.max_y() - 40.0, w, h + 40.0),
        ),
        // Top-right corner (extends right)
        (
            (screen.max_x() - 1.0, screen.min_y() + 36.0),
            Rect::new(screen.max_x(), screen.min_y(), w, h + 36.0),
        ),
        // Top-left corner (extends left)
        (
            (screen.min_x() - w + 1.0, screen.min_y() + 36.0),
            Rect::new(screen.min_x() - w, screen.min_y(), w, h + 36.0),
        ),
    ];

    for (origin, spill) in &candidates {
        if !others.iter().any(|other| other.intersects(spill)) {
            return *origin;
        }
    }
    candidates[0].0
}

/// Returns true when `frame` is parked at the 1px horizontal outer edge of `screen`.
pub fn is_parked_window_frame(frame: Rect, screen: Rect) -> bool {
    if !screen.intersects(&frame) {
        return false;
    }
    frame.min_x() >= screen.max_x() - 3.0 || frame.max_x() <= screen.min_x() + 3.0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VisibleWindowCandidate {
    pub pid: i32,
    pub window_id: Option<u32>,
    pub bounds: Rect,
}

/// Matches an Accessibility window against CoreGraphics on-screen layer-0 windows.
pub fn matches_visible_window(
    pid: i32,
    ax_window_id: Option<u32>,
    ax_frame: Rect,
    candidates: &[VisibleWindowCandidate],
) -> bool {
    let valid_wid = ax_window_id.filter(|&id| id != 0);
    candidates.iter().any(|c| {
        if c.pid != pid {
            return false;
        }
        if let Some(wid) = valid_wid {
            if c.window_id == Some(wid) {
                return true;
            }
        }
        (c.bounds.min_x() - ax_frame.min_x()).abs() < 3.0
            && (c.bounds.min_y() - ax_frame.min_y()).abs() < 3.0
            && (c.bounds.w - ax_frame.w).abs() < 3.0
            && (c.bounds.h - ax_frame.h).abs() < 3.0
    })
}

/// Detects whether the current GUI login session is locked or switched off-console.
pub fn is_session_locked(
    screen_is_locked: Option<bool>,
    on_console: Option<bool>,
    frontmost_bundle_id: Option<&str>,
) -> bool {
    if frontmost_bundle_id == Some("com.apple.loginwindow") {
        return true;
    }
    if screen_is_locked == Some(true) {
        return true;
    }
    if on_console == Some(false) {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_screen_geometry_and_parking() {
        let primary = accessibility_frame(Rect::new(0.0, 25.0, 1440.0, 852.0), 900.0);
        assert_eq!(primary, Rect::new(0.0, 23.0, 1440.0, 852.0));

        let left = accessibility_frame(Rect::new(-1920.0, -100.0, 1920.0, 1050.0), 900.0);
        assert_eq!(left, Rect::new(-1920.0, -50.0, 1920.0, 1050.0));

        let main_screen = Rect::new(0.0, 0.0, 1710.0, 1107.0);
        let single_origin = parked_window_origin(900.0, 700.0, main_screen, &[main_screen]);
        assert_eq!(single_origin, (1709.0, 1106.0));

        let clamped_parked = Rect::new(1709.0, 1075.0, 900.0, 700.0);
        assert!(is_parked_window_frame(clamped_parked, main_screen));
        assert!(!is_parked_window_frame(
            Rect::new(0.0, 34.0, 855.0, 1073.0),
            main_screen
        ));

        let right_screen = Rect::new(1710.0, 0.0, 1920.0, 1080.0);
        let dual_origin =
            parked_window_origin(900.0, 700.0, main_screen, &[main_screen, right_screen]);
        assert_eq!(dual_origin, (-899.0, 1106.0));

        let candidates = vec![
            VisibleWindowCandidate {
                pid: 29852,
                window_id: Some(82740),
                bounds: Rect::new(0.0, 34.0, 1710.0, 1073.0),
            },
            VisibleWindowCandidate {
                pid: 52812,
                window_id: Some(83178),
                bounds: Rect::new(0.0, 34.0, 855.0, 1073.0),
            },
        ];
        assert!(matches_visible_window(
            29852,
            Some(82740),
            Rect::new(8.0, 42.0, 1694.0, 1057.0),
            &candidates
        ));
        assert!(matches_visible_window(
            52812,
            None,
            Rect::new(1.0, 35.0, 855.0, 1073.0),
            &candidates
        ));
        assert!(!matches_visible_window(
            29852,
            Some(99999),
            Rect::new(100.0, 100.0, 800.0, 600.0),
            &candidates
        ));

        assert!(!is_session_locked(
            None,
            Some(true),
            Some("com.mitchellh.ghostty")
        ));
        assert!(is_session_locked(
            Some(true),
            Some(true),
            Some("com.mitchellh.ghostty")
        ));
        assert!(is_session_locked(None, Some(false), None));
        assert!(is_session_locked(None, None, Some("com.apple.loginwindow")));
    }
}
