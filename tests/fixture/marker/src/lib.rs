use proc_macro::TokenStream;

#[proc_macro_derive(Marker)]
pub fn marker(_input: TokenStream) -> TokenStream {
    include_str!("../expansion.rs").parse().unwrap()
}
