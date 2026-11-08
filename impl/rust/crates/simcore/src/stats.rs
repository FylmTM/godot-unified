//! Timing statistics for `bench`.

#[derive(Default)]
pub struct Samples(Vec<f64>);

impl Samples {
    pub fn push(&mut self, us: f64) {
        self.0.push(us);
    }

    pub fn mean(&self) -> f64 {
        if self.0.is_empty() { 0.0 } else { self.0.iter().sum::<f64>() / self.0.len() as f64 }
    }

    /// Nearest-rank p99 (sorted index ceil(0.99 n) - 1).
    pub fn p99(&self) -> f64 {
        if self.0.is_empty() {
            return 0.0;
        }
        let mut v = self.0.clone();
        v.sort_by(|a, b| a.total_cmp(b));
        let idx = ((0.99 * v.len() as f64).ceil() as usize).max(1) - 1;
        v[idx.min(v.len() - 1)]
    }

    pub fn json(&self) -> crate::json::Json {
        crate::json::Json::obj().with("mean", self.mean()).with("p99", self.p99())
    }
}
