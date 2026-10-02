///|
fn cell(
  row : Int,
  column : Int,
  width : Double,
  min : Double,
  colspan? : Int = 1,
  master? : Int = -1,
) -> @table.WidthCell {
  { row, column, colspan, master, width, min, }
}

///|
test "column widths: natural widths when they fit" {
  let cells = [
    cell(0, 0, 50.0, 10.0),
    cell(0, 1, 80.0, 10.0),
    cell(1, 0, 60.0, 10.0),
    cell(1, 1, 30.0, 10.0),
  ]
  debug_inspect(
    @table.column_widths(cells, 2, 500.0, table_width=140.0),
    content="[60, 80]",
  )
}

///|
test "column widths: shrink towards the minimum widths" {
  // natural 60 + 80 = 140 in 100, minimums 20 + 40: each column keeps its
  // minimum and half of the rest ((100 - 60) / (140 - 60))
  let cells = [cell(0, 0, 60.0, 20.0), cell(0, 1, 80.0, 40.0)]
  debug_inspect(
    @table.column_widths(cells, 2, 100.0),
    content=(
      #|[40, 60]
    ),
  )
}

///|
test "column widths: grow towards the bounds" {
  let cells = [cell(0, 0, 20.0, 5.0), cell(0, 1, 30.0, 5.0)]
  debug_inspect(
    @table.column_widths(cells, 2, 100.0, table_width=100.0),
    content=(
      #|[46.666666666666664, 53.33333333333333]
    ),
  )
}

///|
test "column widths: a span wider than its columns is shared evenly" {
  // row 0: one cell spanning both columns (and its dummy); row 1: two
  // narrow cells
  let cells = [
    cell(0, 0, 120.0, 10.0, colspan=2),
    cell(0, 1, 0.0, 0.0, master=0),
    cell(1, 0, 20.0, 10.0),
    cell(1, 1, 30.0, 10.0),
  ]
  debug_inspect(
    @table.column_widths(cells, 2, 500.0, table_width=120.0),
    content="[60, 60]",
  )
}

///|
test "row heights: a cell's height is shared among the rows it spans" {
  debug_inspect(
    @table.row_heights([(0, 1, 10.0), (0, 2, 30.0), (1, 1, 12.0)], 2),
    content="[15, 15]",
  )
}
