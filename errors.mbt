///|
/// The errors Prawn raises (`Prawn::Errors`).
pub(all) suberror PrawnError {
  /// a box too narrow for even one character of its text
  CannotFit
  /// text a standard (AFM) font cannot encode: its characters must be in
  /// Windows-1252
  IncompatibleStringEncoding(String)
  /// Ruby's `ArgumentError`: an argument Prawn rejects (a zero or negative
  /// dash, a malformed colour)
  ArgumentError(String)
  /// pdf-core's: a graphics state restored with none saved on the page (a
  /// page made inside two nested blocks that save it)
  EmptyGraphicStateStack
  /// something Prawn does that this module does not do yet (CMYK colour,
  /// character spacing): raised rather than set wrongly
  Unsupported(String)
}

///|
/// The Ruby class of the error, as Prawn names it.
pub fn PrawnError::ruby_class(self : PrawnError) -> String {
  match self {
    CannotFit => "Prawn::Errors::CannotFit"
    IncompatibleStringEncoding(_) => "Prawn::Errors::IncompatibleStringEncoding"
    ArgumentError(_) => "ArgumentError"
    EmptyGraphicStateStack => "PDF::Core::Errors::EmptyGraphicStateStack"
    Unsupported(_) => "Unsupported"
  }
}
