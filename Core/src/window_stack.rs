/// XMonad-style focused zipper. The first item is the master window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowStack<ID: PartialEq + Clone> {
    pub items: Vec<ID>,
    pub focused: Option<ID>,
}

impl<ID: PartialEq + Clone> Default for WindowStack<ID> {
    fn default() -> Self {
        Self::new()
    }
}

impl<ID: PartialEq + Clone> WindowStack<ID> {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            focused: None,
        }
    }

    pub fn insert(&mut self, id: ID) {
        if self.items.contains(&id) {
            return;
        }
        if let Some(ref f) = self.focused {
            if let Some(idx) = self.items.iter().position(|x| x == f) {
                self.items.insert(idx, id.clone());
                self.focused = Some(id);
                return;
            }
        }
        self.items.insert(0, id.clone());
        self.focused = Some(id);
    }

    pub fn remove(&mut self, id: &ID) {
        let Some(index) = self.items.iter().position(|x| x == id) else {
            return;
        };
        let was_focused = self.focused.as_ref() == Some(id);
        self.items.remove(index);
        if was_focused {
            self.focused = if self.items.is_empty() {
                None
            } else {
                Some(self.items[index % self.items.len()].clone())
            };
        }
    }

    pub fn focus(&mut self, id: &ID) {
        if self.items.contains(id) {
            self.focused = Some(id.clone());
        }
    }

    pub fn focus_next(&mut self, direction: i32) {
        let Some(ref f) = self.focused else { return };
        let Some(i) = self.items.iter().position(|x| x == f) else {
            return;
        };
        if self.items.is_empty() {
            return;
        }
        let n = self.items.len();
        let step = if direction >= 0 { 1 } else { n - 1 };
        let target = (i + step) % n;
        self.focused = Some(self.items[target].clone());
    }

    pub fn swap_next(&mut self, direction: i32) {
        let Some(ref f) = self.focused else { return };
        let Some(i) = self.items.iter().position(|x| x == f) else {
            return;
        };
        let n = self.items.len();
        if n <= 1 {
            return;
        }
        if direction >= 0 && i == n - 1 {
            if let Some(last) = self.items.pop() {
                self.items.insert(0, last);
            }
        } else if direction < 0 && i == 0 {
            let first = self.items.remove(0);
            self.items.push(first);
        } else if direction >= 0 {
            self.items.swap(i, i + 1);
        } else {
            self.items.swap(i, i - 1);
        }
    }

    pub fn swap_master(&mut self) {
        let Some(ref f) = self.focused else { return };
        let Some(i) = self.items.iter().position(|x| x == f) else {
            return;
        };
        self.items.swap(0, i);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_window_stack_operations() {
        let mut s = WindowStack::<i32>::new();
        for w in [1, 2, 3] {
            s.insert(w);
        }
        assert_eq!(s.items, vec![3, 2, 1]);
        assert_eq!(s.focused, Some(3));
        s.focus_next(1);
        assert_eq!(s.focused, Some(2));
        s.swap_master();
        assert_eq!(s.items, vec![2, 3, 1]);
        assert_eq!(s.focused, Some(2));
        s.swap_next(-1);
        assert_eq!(s.items, vec![3, 1, 2]);
        assert_eq!(s.focused, Some(2));
        s.swap_next(1);
        assert_eq!(s.items, vec![2, 3, 1]);
        assert_eq!(s.focused, Some(2));
        s.remove(&2);
        assert_eq!(s.items, vec![3, 1]);
        assert_eq!(s.focused, Some(3));
    }
}
