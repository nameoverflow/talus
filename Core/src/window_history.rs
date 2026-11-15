/// Keeps off-Space windows in the order last assigned while replacing the
/// entries belonging to the current Space with their latest order.
pub fn merge_history<T: Clone, F: Fn(&T, &T) -> bool>(
    history: &[T],
    current: &[T],
    equals: F,
) -> Vec<T> {
    let mut result = history.to_vec();
    for item in current {
        if !result.iter().any(|existing| equals(existing, item)) {
            result.push(item.clone());
        }
    }
    let positions: Vec<usize> = (0..result.len())
        .filter(|&idx| current.iter().any(|c| equals(c, &result[idx])))
        .collect();
    for (idx, item) in positions.into_iter().zip(current.iter()) {
        result[idx] = item.clone();
    }
    result
}

pub fn order_using_history<T: Clone, F: Fn(&T, &T) -> bool>(
    current: &[T],
    history: &[T],
    equals: F,
) -> Vec<T> {
    let mut known: Vec<T> = history
        .iter()
        .filter_map(|old| current.iter().find(|c| equals(c, old)).cloned())
        .collect();
    for item in current {
        if !known.iter().any(|k| equals(k, item)) {
            known.push(item.clone());
        }
    }
    known
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_history_merge_and_order() {
        let mut h = vec![1, 2, 3];
        let space_a_swapped = vec![2, 1];
        h = merge_history(&h, &space_a_swapped, |a, b| a == b);
        assert_eq!(h, vec![2, 1, 3]);
        assert_eq!(order_using_history(&[1, 2], &h, |a, b| a == b), vec![2, 1]);
        assert_eq!(
            order_using_history(&[3, 1, 4], &h, |a, b| a == b),
            vec![1, 3, 4]
        );
    }
}
