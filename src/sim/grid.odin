// Spreading work (src/sim/README.md, Neighbours and time slicing): a uniform grid that finds what is near a point
// without physics, rebuilt from the block when a pass needs it, and `due`, which spreads per-entity work over ticks.
package sim

@(require) import "base:intrinsics" // only in generic procs

@(require) import "unified:dmath" // only in generic procs

// Ids sorted into square cells by a counting sort: scratch in the game's World, never in the block. A pass that needs
// it rebuilds it from the block (grid_begin, grid_add per item, grid_end), so a rollback can never leave it stale,
// and its answers come in a fixed order: by row, then column, then the order the ids were added (a table walked in
// index order gives each cell's ids in index order). CELLS bounds columns × rows, CAP the ids.
Grid :: struct($CELLS: int, $CAP: int) where CELLS > 0 && CAP > 0 {
	origin:     [2]f32, // the corner with the smallest x and y
	cell_size:  f32,
	columns:    i32,
	rows:       i32,
	count:      i32, // ids added since grid_begin
	sorted:     bool, // grid_end ran since the last grid_begin
	cell_start: [CELLS + 1]i32, // cell c's ids are ids[cell_start[c] ..< cell_start[c + 1]]
	ids:        [CAP]i32, // by cell, each cell's in the order added
	added_id:   [CAP]i32,
	added_cell: [CAP]i32,
}

// Starts a rebuild: `columns` × `rows` cells of `cell_size` from `origin` (their smallest corner), empty. columns ×
// rows <= CELLS.
grid_begin :: proc(grid: ^Grid($CELLS, $CAP), origin: [2]f32, cell_size: f32, columns, rows: int) {
	assert(columns > 0 && rows > 0 && columns * rows <= CELLS, "sim.grid_begin: columns * rows must be within CELLS")
	assert(cell_size > 0, "sim.grid_begin: cell_size must be positive")
	grid.origin, grid.cell_size = origin, cell_size
	grid.columns, grid.rows = i32(columns), i32(rows)
	grid.count, grid.sorted = 0, false
}

// The cell holding `pos`: a position outside the grid counts in the edge cell nearest it.
@(private)
grid_cell :: #force_inline proc(grid: ^Grid($CELLS, $CAP), pos: [2]f32) -> (column, row: i32) {
	column = dmath.to_i32_clamped((pos.x - grid.origin.x) / grid.cell_size, 0, grid.columns - 1)
	row = dmath.to_i32_clamped((pos.y - grid.origin.y) / grid.cell_size, 0, grid.rows - 1)
	return
}

// Adds an id at a position (between grid_begin and grid_end); false when CAP ids were added already.
grid_add :: proc(grid: ^Grid($CELLS, $CAP), id: i32, pos: [2]f32) -> bool {
	if grid.count >= i32(CAP) do return false
	column, row := grid_cell(grid, pos)
	grid.added_id[grid.count] = id
	grid.added_cell[grid.count] = row * grid.columns + column
	grid.count += 1
	return true
}

// Finishes a rebuild: sorts the added ids into their cells, each cell's in the order added.
grid_end :: proc(grid: ^Grid($CELLS, $CAP)) {
	cells := int(grid.columns * grid.rows)
	for cell in 0 ..= cells do grid.cell_start[cell] = 0
	for i in 0 ..< grid.count do grid.cell_start[grid.added_cell[i]] += 1
	sum: i32 = 0
	for cell in 0 ..< cells {
		sum += grid.cell_start[cell]
		grid.cell_start[cell] = sum // the cell's end, for now
	}
	grid.cell_start[cells] = sum
	for i := grid.count - 1; i >= 0; i -= 1 { 	// backwards, so each cell keeps the order added
		cell := grid.added_cell[i]
		grid.cell_start[cell] -= 1
		grid.ids[grid.cell_start[cell]] = grid.added_id[i]
	}
	grid.sorted = true
}

// The ids in the 3 × 3 cells around `pos`'s cell, as three runs, one per row from the smallest y (the three cells of
// a row are one contiguous run; a row off the grid is empty). With cell_size at least the reach of a query, these
// are all the candidates within it.
grid_near :: proc(grid: ^Grid($CELLS, $CAP), pos: [2]f32) -> (rows: [3][]i32) {
	assert(grid.sorted, "sim.grid_near: call grid_end first")
	column, row := grid_cell(grid, pos)
	first, last := dmath.max(column - 1, 0), dmath.min(column + 1, grid.columns - 1)
	for k in 0 ..< i32(3) {
		near_row := row - 1 + k
		if near_row < 0 || near_row >= grid.rows do continue
		base := near_row * grid.columns
		rows[k] = grid.ids[grid.cell_start[base + first]:grid.cell_start[base + last + 1]]
	}
	return
}

// A walk over the rows of cells a box covers (grid_box, then next): each yields that row's run of ids.
Grid_Box :: struct($CELLS: int, $CAP: int) {
	grid:                      ^Grid(CELLS, CAP),
	first_column, last_column: i32,
	row, last_row:             i32,
}

// Starts a walk over the cells the box between corners `low` and `high` touches (clamped to the grid; a corner past
// the other on an axis is taken as the box's other side), a row at a time from the smallest y: `next` yields each
// row's ids as one run (the row's cells are contiguous).
grid_box :: proc(grid: ^Grid($CELLS, $CAP), low, high: [2]f32) -> Grid_Box(CELLS, CAP) {
	assert(grid.sorted, "sim.grid_box: call grid_end first")
	first_column, first_row := grid_cell(grid, low)
	last_column, last_row := grid_cell(grid, high)
	if first_column > last_column do first_column, last_column = last_column, first_column
	if first_row > last_row do first_row, last_row = last_row, first_row
	return {grid, first_column, last_column, first_row, last_row}
}

// The next row of a grid_box walk: its ids, as one run; ok is false past the last row.
grid_box_next :: proc(walk: ^Grid_Box($CELLS, $CAP)) -> (ids: []i32, ok: bool) {
	if walk.row > walk.last_row do return
	grid := walk.grid
	base := walk.row * grid.columns
	walk.row += 1
	return grid.ids[grid.cell_start[base + walk.first_column]:grid.cell_start[base + walk.last_column + 1]], true
}

// Whether `key`'s turn comes this tick, once every `period` ticks of game time: (key + t.time) % period == 0, so a
// pause moves no key's turn. Keys spread evenly over
// the period (dense keys: each tick takes a period-th of them), so work too costly every tick for every entity runs
// for each once per period: `if sim.due(t, handle.index, CHECK_TICKS) { ... }`. period > 0 (asserted).
due :: proc(tick: ^Tick($G), key: $K, period: u32) -> bool where intrinsics.type_is_integer(K) {
	assert(period > 0, "sim.due: the period is 0 ticks (a length that rounds to 0?)")
	return (u64(key) + u64(tick.time)) % u64(period) == 0
}
