pub fn render(value: usize) -> String {
    let mut buffer = itoa::Buffer::new();
    format!("audit:{}", buffer.format(value))
}
