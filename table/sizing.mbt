///|
// prawn-table's sizing: the column widths of a table given none
// (ColumnWidthCalculator, Table#column_widths) and the row heights of its
// cells (Table#row_heights).

///|
/// A cell of prawn-table's width calculation: a master cell, or a dummy
/// standing for a place its span covers (Cell::SpanDummy), in the order
/// `make_cells` creates them.
pub(all) struct WidthCell {
  row : Int
  column : Int
  colspan : Int
  /// the master cell this dummy stands for (its index), or -1
  master : Int
  /// width_ignoring_span, min_width_ignoring_span
  width : Double
  min : Double
}

///|
/// `Cells#aggregate_cell_values(:column, :avg_spanned_min_width, :max)`
/// over `cells` (the table's or one column's): each column's largest
/// minimum width, a span's shared evenly among its columns, summed.
fn aggregate_min_widths(
  all : Array[WidthCell],
  cells : Array[WidthCell],
) -> Double {
  let avg = fn(c : WidthCell) {
    if c.master >= 0 {
      let m = all[c.master]
      m.min / m.colspan.to_double()
    } else {
      c.min / c.colspan.to_double()
    }
  }
  let values : Map[Int, Double] = Map([])
  let put_max = fn(i : Int, v : Double) {
    match values.get(i) {
      Some(old) => values[i] = @cmp.maximum(old, v)
      None => values[i] = v
    }
  }
  for c in cells {
    if c.colspan == 1 && c.master < 0 {
      put_max(c.column, c.min)
    }
  }
  let rows_with_dummy : Map[Int, Bool] = Map([])
  for c in cells {
    if c.master >= 0 {
      rows_with_dummy[c.row] = true
    }
  }
  let mut needs_fixing = true
  for c in cells {
    let index = c.column
    if c.colspan > 1 {
      // fill_values_if_needed: some but not all of the span's columns have
      // a value, in a row with a dummy
      let mut missing = 0
      for i in 0..<c.colspan {
        if !values.contains(index + i) {
          missing += 1
        }
      }
      if missing > 0 && missing < c.colspan && rows_with_dummy.contains(c.row) {
        let mut sum = avg(c) * c.colspan.to_double()
        for i in 0..<c.colspan {
          match values.get(index + i) {
            Some(v) => sum -= v
            None => ()
          }
        }
        let share = sum / missing.to_double()
        for i in 0..<c.colspan {
          if !values.contains(index + i) {
            values[index + i] = share
          }
        }
      }
      let mut old_sum = 0.0
      for i in 0..<c.colspan {
        old_sum += values.get(index + i).unwrap_or(0.0)
      }
      let new_sum = avg(c) * c.colspan.to_double()
      needs_fixing = new_sum - old_sum > 1.0e-9
      if needs_fixing {
        put_max(index, avg(c))
        let mut all_exist = true
        for i in 0..<c.colspan {
          if !values.contains(index + i) {
            all_exist = false
          }
        }
        if all_exist {
          for i in 0..<c.colspan {
            values[index + i] = avg(c)
          }
        }
      }
    } else if needs_fixing && c.master >= 0 {
      put_max(index, avg(c))
    }
  }
  let mut total = 0.0
  for _, v in values {
    total += v
  }
  total
}

///|
/// The column widths of a table of `num_cols` columns given none, as
/// prawn-table sizes it: the widest natural width per column
/// (`ColumnWidthCalculator#natural_widths`: the rows without span dummies
/// first, then theirs, a span's width shared evenly among its columns when
/// they are narrower), then shrunk towards the columns' minimum widths when
/// wider than `table_width` (default: the natural width, at most
/// `bounds_width`), or grown towards `bounds_width` per column when
/// narrower. `cells` are the master cells and the span dummies in the order
/// prawn-table's `make_cells` creates them.
pub fn column_widths(
  cells : Array[WidthCell],
  num_cols : Int,
  bounds_width : Double,
  table_width? : Double,
) -> Array[Double] {
  let rows_with_dummy : Map[Int, Bool] = Map([])
  for c in cells {
    if c.master >= 0 {
      rows_with_dummy[c.row] = true
    }
  }
  let natural = Array::make(num_cols, 0.0)
  for c in cells {
    if !rows_with_dummy.contains(c.row) && c.master < 0 {
      natural[c.column] = @cmp.maximum(natural[c.column], c.width)
    }
  }
  for c in cells {
    if !rows_with_dummy.contains(c.row) || c.master >= 0 {
      continue
    }
    if c.colspan == 1 {
      natural[c.column] = @cmp.maximum(natural[c.column], c.width)
    } else {
      let mut current = 0.0
      for i in c.column..<@cmp.minimum(c.column + c.colspan, num_cols) {
        current += natural[i]
      }
      if c.width - current > 1.0e-9 {
        for i in c.column..<@cmp.minimum(c.column + c.colspan, num_cols) {
          natural[i] = c.width / c.colspan.to_double()
        }
      }
    }
  }
  let natural_width = natural.fold(init=0.0, (a, b) => a + b)
  let width = table_width.unwrap_or(@cmp.minimum(natural_width, bounds_width))
  if width - natural_width < -1.0e-9 {
    // shrink towards each column's minimum width
    let min_width = aggregate_min_widths(cells, cells)
    let f = (width - min_width) / (natural_width - min_width)
    Array::makei(num_cols, c => {
      let min = aggregate_min_widths(
        cells,
        cells.filter(cell => cell.column == c),
      )
      f * (natural[c] - min) + min
    })
  } else if width - natural_width > 1.0e-9 {
    // grow towards each column's maximum width (the bounds' width)
    let f = (width - natural_width) /
      (bounds_width * num_cols.to_double() - natural_width)
    natural.map(nat => f * (bounds_width - nat) + nat)
  } else {
    natural
  }
}

///|
/// The height of each of `num_rows` rows (prawn-table's `row_heights`): the
/// tallest share of the cells in it, a cell's `height` shared evenly among
/// the `rowspan` rows from `row` it spans.
pub fn row_heights(
  cells : Array[(Int, Int, Double)],
  num_rows : Int,
) -> Array[Double] {
  let heights = Array::make(num_rows, 0.0)
  for cell in cells {
    let (row, rowspan, height) = cell
    let share = height / rowspan.to_double()
    for i in 0..<rowspan {
      if share > heights[row + i] {
        heights[row + i] = share
      }
    }
  }
  heights
}
