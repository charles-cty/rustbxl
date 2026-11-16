mod additional;

pub fn render(value: usize) -> String {
    let mut buffer = itoa::Buffer::new();
    format!("{}:{}", additional::MARKER, buffer.format(value))
}
