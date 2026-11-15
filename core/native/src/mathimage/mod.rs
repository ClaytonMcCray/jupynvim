//! Display math typeset to a PNG. The engine arrives in its own change; until then both
//! job kinds answer with errors of the final shape.
use crate::jobs::{JobCx, JobErr};

/// JNV_KIND_MATH.
pub fn run_typeset(input: &[u8], _cx: &JobCx) -> Result<Vec<u8>, JobErr> {
    if !input.starts_with(b"JNM 1\n") {
        return Err(JobErr::Err("math: request: line 1: wants JNM 1".to_string()));
    }
    Err(JobErr::Err("math: internal: the engine is not built in".to_string()))
}

/// JNV_KIND_MATH_CELL.
pub fn run_cell(input: &[u8]) -> Result<Vec<u8>, String> {
    if !input.is_empty() {
        return Err("math cell: no input is expected".to_string());
    }
    Err("math cell: no terminal".to_string())
}
