use serde::{Deserialize, Serialize};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }

    pub fn min_y(&self) -> f64 {
        self.y
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        if self.w <= 0.0 || self.h <= 0.0 || other.w <= 0.0 || other.h <= 0.0 {
            return false;
        }
        self.min_x() < other.max_x()
            && self.max_x() > other.min_x()
            && self.min_y() < other.max_y()
            && self.max_y() > other.min_y()
    }

    pub fn intersection_area(&self, other: &Rect) -> f64 {
        let x1 = self.min_x().max(other.min_x());
        let y1 = self.min_y().max(other.min_y());
        let x2 = self.max_x().min(other.max_x());
        let y2 = self.max_y().min(other.max_y());
        if x2 > x1 && y2 > y1 {
            (x2 - x1) * (y2 - y1)
        } else {
            0.0
        }
    }
}

pub fn inset_area(area: Rect, outer_gap: f64) -> Rect {
    let g = outer_gap.max(0.0).round();
    if g <= 0.0 {
        return area;
    }
    let ox = g.min(((area.w - 40.0).max(0.0) / 2.0).floor());
    let oy = g.min(((area.h - 40.0).max(0.0) / 2.0).floor());
    Rect::new(
        area.x + ox,
        area.y + oy,
        area.w - 2.0 * ox,
        area.h - 2.0 * oy,
    )
}

fn split_vertical_with_gap(rect: Rect, n: usize, inner_gap: f64) -> Vec<Rect> {
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![rect];
    }
    let g = inner_gap
        .max(0.0)
        .round()
        .min(((rect.h - (n as f64) * 20.0).max(0.0) / ((n - 1) as f64)).floor());
    let mut out = Vec::with_capacity(n);
    let mut y = rect.y;
    let mut remaining_h = rect.h - g * ((n - 1) as f64);
    let mut remaining = n;
    while remaining > 1 {
        let h = (remaining_h / (remaining as f64)).floor();
        out.push(Rect::new(rect.x, y, rect.w, h));
        y += h + g;
        remaining_h -= h;
        remaining -= 1;
    }
    out.push(Rect::new(rect.x, y, rect.w, remaining_h));
    out
}

pub fn tall_layout_with_gaps(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    outer_gap: f64,
    inner_gap: f64,
) -> Vec<Rect> {
    if count == 0 {
        return Vec::new();
    }
    let inset = inset_area(area, outer_gap);
    if count <= masters || masters == 0 {
        return split_vertical_with_gap(inset, count, inner_gap);
    }
    let col_gap = inner_gap
        .max(0.0)
        .round()
        .min((inset.w - 40.0).max(0.0).floor());
    let usable_w = inset.w - col_gap;
    let left_w = (usable_w * ratio).floor();
    let right_w = usable_w - left_w;
    let mut left = split_vertical_with_gap(
        Rect::new(inset.x, inset.y, left_w, inset.h),
        masters,
        inner_gap,
    );
    let right = split_vertical_with_gap(
        Rect::new(inset.x + left_w + col_gap, inset.y, right_w, inset.h),
        count - masters,
        inner_gap,
    );
    left.extend(right);
    left
}

pub fn mirror_tall_layout_with_gaps(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    outer_gap: f64,
    inner_gap: f64,
) -> Vec<Rect> {
    let rotated = Rect::new(area.y, area.x, area.h, area.w);
    tall_layout_with_gaps(rotated, count, masters, ratio, outer_gap, inner_gap)
        .into_iter()
        .map(|r| Rect::new(r.y, r.x, r.h, r.w))
        .collect()
}

pub fn tall_layout(area: Rect, count: usize, masters: usize, ratio: f64) -> Vec<Rect> {
    tall_layout_with_gaps(area, count, masters, ratio, 0.0, 0.0)
}

pub fn mirror_tall_layout(area: Rect, count: usize, masters: usize, ratio: f64) -> Vec<Rect> {
    mirror_tall_layout_with_gaps(area, count, masters, ratio, 0.0, 0.0)
}

pub fn centered_frame(win_w: f64, win_h: f64, area: Rect) -> Rect {
    let w = win_w.max(240.0).min(area.w * 0.9);
    let h = win_h.max(180.0).min(area.h * 0.9);
    Rect::new(
        area.min_x() + ((area.w - w) / 2.0).round(),
        area.min_y() + ((area.h - h) / 2.0).round(),
        w,
        h,
    )
}

pub fn centered_origin(win_w: f64, win_h: f64, area: Rect) -> (f64, f64) {
    let x = area
        .min_x()
        .max(area.min_x() + ((area.w - win_w) / 2.0).round());
    let y = area
        .min_y()
        .max(area.min_y() + ((area.h - win_h) / 2.0).round());
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tall_and_mirror_layouts() {
        let area = Rect::new(-100.0, 20.0, 1000.0, 801.0);
        let one = tall_layout(area, 1, 1, 0.5);
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].w, 1000.0);
        assert_eq!(one[0].x, -100.0);

        let three = tall_layout(area, 3, 1, 0.5);
        assert_eq!(three.len(), 3);
        assert_eq!(three[0].w, 500.0);
        assert_eq!(three[1].h, 400.0);
        assert_eq!(three[2].h, 401.0);
        assert_eq!(three[2].y, 420.0);

        let multi = tall_layout(area, 4, 2, 0.6);
        assert_eq!(multi.len(), 4);
        assert_eq!(multi[0].w, 600.0);
        assert_eq!(multi[1].h, 401.0);
        assert_eq!(multi[2].w, 400.0);

        let mirror = mirror_tall_layout(area, 3, 1, 0.5);
        assert_eq!(mirror[0].h, 400.0);
        assert_eq!(mirror[0].w, 1000.0);
        assert_eq!(mirror[1].x, -100.0);
        assert_eq!(mirror[2].x, 400.0);
        assert_eq!(mirror[2].y, 420.0);

        assert!(tall_layout(area, 0, 1, 0.5).is_empty());

        // Margins and inner gaps
        let gapped =
            tall_layout_with_gaps(Rect::new(0.0, 0.0, 1000.0, 800.0), 3, 1, 0.5, 10.0, 8.0);
        assert_eq!(gapped.len(), 3);
        // Inset area: x=10, y=10, w=980, h=780
        // Column gap = 8 -> usable_w = 972 -> left_w = 486, right_w = 486
        assert_eq!(gapped[0], Rect::new(10.0, 10.0, 486.0, 780.0));
        // Right stack: 2 windows in h=780 with inner_gap=8 -> usable_h=772 -> 386 each
        assert_eq!(gapped[1], Rect::new(504.0, 10.0, 486.0, 386.0));
        assert_eq!(gapped[2], Rect::new(504.0, 404.0, 486.0, 386.0));
        assert!(!gapped[0].intersects(&gapped[1]));
        assert!(!gapped[1].intersects(&gapped[2]));
    }

    #[test]
    fn test_layout_area_conservation_properties() {
        let area = Rect::new(0.0, 25.0, 1440.0, 875.0);
        for count in 1..=12 {
            for masters in 0..=4 {
                for ratio_pct in [20, 35, 50, 65, 80] {
                    let ratio = (ratio_pct as f64) / 100.0;
                    for rects in [
                        tall_layout(area, count, masters, ratio),
                        mirror_tall_layout(area, count, masters, ratio),
                    ] {
                        assert_eq!(rects.len(), count);
                        let sum_area: f64 = rects.iter().map(|r| r.w * r.h).sum();
                        assert!((sum_area - area.w * area.h).abs() < 1e-6);
                        for i in 0..rects.len() {
                            assert!(rects[i].w > 0.0 && rects[i].h > 0.0);
                            assert!(rects[i].min_x() >= area.min_x());
                            assert!(rects[i].min_y() >= area.min_y());
                            assert!(rects[i].max_x() <= area.max_x());
                            assert!(rects[i].max_y() <= area.max_y());
                            for j in (i + 1)..rects.len() {
                                assert!(!rects[i].intersects(&rects[j]));
                            }
                        }
                    }
                }
            }
        }
    }
}
