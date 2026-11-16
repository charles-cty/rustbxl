pub fn render(value: usize) -> String {
    let mut buffer = itoa::Buffer::new();
    format!("planner-near:{}", buffer.format(value))
}
