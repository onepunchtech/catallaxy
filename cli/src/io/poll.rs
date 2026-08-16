use std::time::{Duration, Instant};

pub fn poll_while_time_remains<T>(
    budget: Duration,
    interval: Duration,
    mut probe: impl FnMut() -> Option<T>,
) -> Option<T> {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if let Some(answer) = probe() {
            return Some(answer);
        }
        std::thread::sleep(interval);
    }
    None
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn an_answer_on_the_first_attempt_costs_no_waiting() {
        let started = Instant::now();
        let answer =
            poll_while_time_remains(Duration::from_secs(60), Duration::from_secs(60), || {
                Some("ready")
            });
        assert_eq!(answer, Some("ready"));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_spent_budget_starts_no_attempt_at_all() {
        let attempts = Cell::new(0);
        let answer = poll_while_time_remains(Duration::ZERO, Duration::from_millis(1), || {
            attempts.set(attempts.get() + 1);
            Some(())
        });
        assert_eq!(answer, None);
        assert_eq!(attempts.get(), 0);
    }

    #[test]
    fn attempts_repeat_until_one_of_them_answers() {
        let attempts = Cell::new(0);
        let answer =
            poll_while_time_remains(Duration::from_secs(30), Duration::from_millis(1), || {
                attempts.set(attempts.get() + 1);
                (attempts.get() == 3).then_some("ready")
            });
        assert_eq!(answer, Some("ready"));
        assert_eq!(attempts.get(), 3);
    }

    #[test]
    fn a_probe_that_never_answers_gives_up_when_the_budget_runs_out() {
        let attempts = Cell::new(0);
        let answer = poll_while_time_remains(
            Duration::from_millis(20),
            Duration::from_millis(1),
            || -> Option<()> {
                attempts.set(attempts.get() + 1);
                None
            },
        );
        assert_eq!(answer, None);
        assert!(attempts.get() >= 1);
    }
}
