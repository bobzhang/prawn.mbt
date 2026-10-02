///|
/// The errors Prawn raises (`Prawn::Errors`).
pub(all) suberror PrawnError {
  /// a box too narrow for even one character of its text
  CannotFit
  /// text a standard (AFM) font cannot encode: its characters must be in
  /// Windows-1252
  IncompatibleStringEncoding(String)
}

///|
/// The Ruby class of the error, as Prawn names it.
pub fn PrawnError::ruby_class(self : PrawnError) -> String {
  match self {
    CannotFit => "Prawn::Errors::CannotFit"
    IncompatibleStringEncoding(_) => "Prawn::Errors::IncompatibleStringEncoding"
  }
}
