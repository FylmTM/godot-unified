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
	sorted:     bool, // grid_end ran since the last grid_begin or grid_add
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

// The cell holding `pos`, as the grid files it and grid_near / grid_box look it up: a position outside the grid counts
// in the edge cell nearest it.
grid_cell :: #force_inline proc(grid: ^Grid($CELLS, $CAP), pos: [2]f32) -> (column, row: i32) {
	column = dmath.to_i32_clamped((pos.x - grid.origin.x) / grid.cell_size, 0, grid.columns - 1)
	row = dmath.to_i32_clamped((pos.y - grid.origin.y) / grid.cell_size, 0, grid.rows - 1)
	return
}

// The cell holding `pos` (grid_cell) as one index, 0 ..< grid_cells(grid): for a game's own table beside the grid, a
// flag or a count per cell, kept in step with the cells the grid's queries walk.
grid_cell_index :: #force_inline proc(grid: ^Grid($CELLS, $CAP), pos: [2]f32) -> int {
	column, row := grid_cell(grid, pos)
	return int(row * grid.columns + column)
}

// How many cells the grid laid out at its grid_begin (columns × rows, at most CELLS).
grid_cells :: #force_inline proc(grid: ^Grid($CELLS, $CAP)) -> int {
	return int(grid.columns * grid.rows)
}

// Adds an id at a position (between grid_begin and grid_end); false when CAP ids were added already, which changes
// nothing. An add after grid_end makes the grid unsorted again: a query asserts until the next grid_end, which sorts
// everything added.
grid_add :: proc(grid: ^Grid($CELLS, $CAP), id: i32, pos: [2]f32) -> bool {
	if grid.count >= i32(CAP) do return false
	grid.sorted = false
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
	for run, k in grid_around(grid, column, row) do rows[k] = grid.ids[run.first:run.end]
	return
}

// A run of grid positions, first ..< end: the ids at grid_ids(grid)[first:end]. A position is an id's index in the
// grid's order, so a pass that copies what it reads of each item into an array by position (once, before walking
// pairs) reads its neighbours from contiguous memory.
Grid_Run :: struct {
	first, end: i32,
}

// Every id added since grid_begin, in the grid's order: by row from the smallest y, then column, then the order added.
// An id's index in it is its grid position, what Grid_Run and grid_pairs name.
grid_ids :: proc(grid: ^Grid($CELLS, $CAP)) -> []i32 {
	assert(grid.sorted, "sim.grid_ids: call grid_end first")
	return grid.ids[:grid.count]
}

// The 3 × 3 cells around the cell at `column`, `row` (grid_cell's, on the grid) as three runs of grid positions, one
// per row from the smallest y: grid_near as positions. A row's three cells are one run, a row off the grid an empty
// one.
grid_around :: proc(grid: ^Grid($CELLS, $CAP), column, row: i32) -> (rows: [3]Grid_Run) {
	assert(grid.sorted, "sim.grid_around: call grid_end first")
	assert(column >= 0 && column < grid.columns && row >= 0 && row < grid.rows, "sim.grid_around: a cell off the grid")
	first, last := dmath.max(column - 1, 0), dmath.min(column + 1, grid.columns - 1)
	for k in 0 ..< i32(3) {
		near_row := row - 1 + k
		if near_row < 0 || near_row >= grid.rows do continue
		base := near_row * grid.columns
		rows[k] = {grid.cell_start[base + first], grid.cell_start[base + last + 1]}
	}
	return
}

// A walk over every id in grid order, each with its neighbours after it (grid_pairs, then next).
Grid_Pairs :: struct($CELLS: int, $CAP: int) {
	grid:         ^Grid(CELLS, CAP),
	position:     i32, // the next to yield
	cell:         i32, // the cell holding the last yielded
	cell_end:     i32, // one past the cell's last position
	row_end:      i32, // one past the position of the last id in the cell after it in its row (or in it, at the edge)
	next_row_run: Grid_Run, // the 3 cells below it in the next row
}

// Starts a walk that meets each pair of ids in neighbouring cells (the 3 × 3 around either) once: `next` yields every
// position in grid order with `later`, two runs of the positions after it in its 3 × 3 cells (the rest of its cell and
// the cell after it in its row, then the next row's three). A pass that sums a pairwise force adds it to both items,
// opposite ways, and visits each pair once instead of twice:
//
//	pairs := sim.grid_pairs(grid)
//	for k, later in sim.next(&pairs) {
//		for run in later do for j in run.first ..< run.end { ... }
//	}
//
// Each item's sums then add up in grid order, not in the order of its own neighbour walk.
grid_pairs :: proc(grid: ^Grid($CELLS, $CAP)) -> Grid_Pairs(CELLS, CAP) {
	assert(grid.sorted, "sim.grid_pairs: call grid_end first")
	return {grid = grid, cell = -1}
}

// The next position of a grid_pairs walk, with the two runs of its neighbours after it in grid order; ok is false
// past the last id.
grid_pairs_next :: proc(walk: ^Grid_Pairs($CELLS, $CAP)) -> (position: i32, later: [2]Grid_Run, ok: bool) {
	grid := walk.grid
	if walk.position >= grid.count do return
	if walk.position >= walk.cell_end {
		for walk.cell_end <= walk.position { 	// the next cell with ids: cell_start[columns × rows] is count
			walk.cell += 1
			walk.cell_end = grid.cell_start[walk.cell + 1]
		}
		column, row := walk.cell % grid.columns, walk.cell / grid.columns
		walk.row_end = grid.cell_start[row * grid.columns + dmath.min(column + 1, grid.columns - 1) + 1]
		walk.next_row_run = {}
		if row + 1 < grid.rows {
			base := (row + 1) * grid.columns
			walk.next_row_run = {
				grid.cell_start[base + dmath.max(column - 1, 0)],
				grid.cell_start[base + dmath.min(column + 1, grid.columns - 1) + 1],
			}
		}
	}
	position = walk.position
	walk.position += 1
	return position, {{position + 1, walk.row_end}, walk.next_row_run}, true
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
