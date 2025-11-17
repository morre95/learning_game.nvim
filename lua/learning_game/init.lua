local M = {}
local uv = vim.uv or vim.loop

local default_config = {
	assignment_count = 20,
	assignment_symbols = { "x", "r" },
	line_numbers = {
		enabled = true,
		relative = true,
	},
	board = {
		width = 56,
		height = 18,
	},
}

local config = vim.deepcopy(default_config)
local KEY_NS = vim.api.nvim_create_namespace("learning_game_key_tracker")
local MARK_NS = vim.api.nvim_create_namespace("learning_game_markers")
local assignment_types = {}
math.randomseed(uv.hrtime() % 1e9)

local function shuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

local function calc_popup_size(lines)
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.api.nvim_strwidth(line))
	end
	local padding = 4
	local height = #lines + 2
	return width + padding, height
end

local Game = {}
Game.__index = Game

function Game:new(cfg)
	local obj = setmetatable({}, Game)
	obj.config = cfg
	obj.completed = 0
	obj.active = false
	obj.key_count = 0
	obj.total_assignments = cfg.assignment_count
	obj.assignment_queue = {}
	obj.current_assignment = nil

	return obj
end

function Game:start()
	self:open_board()
	self.active = true
	self.start_time = uv.hrtime()
	self:populate_assignments()
	self:start_tracking()
	self:update_status()
end

function Game:open_board()
	vim.cmd("tabnew")
	self.win = vim.api.nvim_get_current_win()
	self.buf = vim.api.nvim_get_current_buf()
	local line_numbers = self.config.line_numbers or {}
	local numbers_enabled = line_numbers.enabled ~= false
	local relative_numbers = numbers_enabled and line_numbers.relative == true
	vim.bo[self.buf].bufhidden = "wipe"
	vim.bo[self.buf].buftype = "nofile"
	vim.bo[self.buf].swapfile = false
	vim.bo[self.buf].filetype = "learninggame"
	vim.bo[self.buf].modifiable = true
	vim.bo[self.buf].readonly = false
	vim.wo[self.win].number = numbers_enabled
	vim.wo[self.win].relativenumber = relative_numbers
	vim.wo[self.win].cursorline = false
	vim.api.nvim_buf_set_name(self.buf, "LearningGame")

	local lines = {}
	for _ = 1, self.config.board.height do
		lines[#lines + 1] = string.rep(".", self.config.board.width)
	end
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)

	vim.keymap.set("n", "q", function()
		if self.active then
			self:finish(true)
		else
			vim.cmd("tabclose")
		end
	end, { buffer = self.buf, nowait = true, desc = "Quit LearningGame" })
end

function Game:random_positions(count)
	local cells = {}
	for line = 1, self.config.board.height do
		for col = 1, self.config.board.width do
			cells[#cells + 1] = { line = line, col = col }
		end
	end
	shuffle(cells)
	local result = {}
	for i = 1, count do
		result[i] = cells[i]
	end
	return result
end

function Game:assignment_pool()
	local pool = {}
	while #pool < self.config.assignment_count do
		for _, symbol in ipairs(self.config.assignment_symbols) do
			pool[#pool + 1] = symbol
			if #pool == self.config.assignment_count then
				break
			end
		end
	end
	shuffle(pool)
	return pool
end

function Game:populate_assignments()
	self.assignment_queue = {}
	local positions = self:random_positions(self.config.assignment_count)
	local pool = self:assignment_pool()
	for i = 1, self.config.assignment_count do
		local symbol = pool[i]
		local handler = assignment_types[symbol]
		if handler then
			local assignment = {
				id = i,
				type = symbol,
				line = positions[i].line,
				col = positions[i].col,
				done = false,
			}
			table.insert(self.assignment_queue, assignment)
		else
			vim.notify(string.format("LearningGame: no assignment handler for '%s'", symbol), vim.log.levels.ERROR)
		end
	end
	self:spawn_next_assignment()
end

function Game:spawn_next_assignment()
	if not self.active then
		return
	end
	if self.current_assignment then
		return
	end
	local assignment = table.remove(self.assignment_queue, 1)
	if not assignment then
		self:display_tip()
		return
	end
	assignment.done = false
	assignment.notified = false
	self.current_assignment = assignment
	self:set_char(assignment.line, assignment.col, assignment.type)
	self:create_marker(assignment)
	self:update_status()
	self:display_tip()
end

function Game:set_char(line, col, char)
	if not vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	local line_text = vim.api.nvim_buf_get_lines(self.buf, line - 1, line, false)[1] or ""
	if #line_text < col - 1 then
		line_text = line_text .. string.rep(".", (col - 1) - #line_text)
	end
	if #line_text < col then
		line_text = line_text .. "."
	end
	local before = line_text:sub(1, col - 1)
	local after = line_text:sub(col + 1)
	local new_line = before .. char .. after
	vim.api.nvim_buf_set_lines(self.buf, line - 1, line, false, { new_line })
end

function Game:get_line(line)
	return vim.api.nvim_buf_get_lines(self.buf, line - 1, line, false)[1] or ""
end

function Game:get_char(line, col)
	local line_text = self:get_line(line)
	if col > #line_text then
		return ""
	end
	return line_text:sub(col, col)
end

function Game:get_assignment_coords(assignment)
	if assignment.mark_id and vim.api.nvim_buf_is_valid(self.buf) then
		local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, self.buf, MARK_NS, assignment.mark_id, {})
		if ok and pos and pos[1] then
			assignment.line = pos[1] + 1
			assignment.col = pos[2] + 1
		end
	end
	return assignment.line, assignment.col
end

function Game:get_assignment_char(assignment)
	local line, col = self:get_assignment_coords(assignment)
	return self:get_char(line, col), line, col
end

function Game:create_marker(assignment)
	assignment.mark_id = vim.api.nvim_buf_set_extmark(self.buf, MARK_NS, assignment.line - 1, assignment.col - 1, {
		end_row = assignment.line - 1,
		end_col = assignment.col,
		hl_group = "LearningGameAssignment",
		right_gravity = false,
	})
end

function Game:clear_marker(assignment)
	if assignment.mark_id then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, MARK_NS, assignment.mark_id)
		assignment.mark_id = nil
	end
end

function Game:start_tracking()
	self.augroup = vim.api.nvim_create_augroup("LearningGame" .. self.buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = self.buf,
		group = self.augroup,
		callback = function()
			self:evaluate_assignments()
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = self.buf,
		group = self.augroup,
		callback = function()
			self:on_cursor_moved()
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = self.buf,
		group = self.augroup,
		callback = function()
			if self.active then
				self:finish(true)
			end
		end,
	})

	self.key_handler = function(_)
		if not self.active then
			return
		end
		if vim.api.nvim_get_current_buf() ~= self.buf then
			return
		end
		self.key_count = self.key_count + 1
		self:update_status()
	end
	vim.on_key(self.key_handler, KEY_NS)
end

function Game:evaluate_assignments()
	if not self.active then
		return
	end
	local assignment = self.current_assignment
	if not assignment or assignment.done then
		return
	end
	local handler = assignment_types[assignment.type]
	if handler and handler.check then
		local ok = handler.check(self, assignment)
		if ok then
			self:mark_assignment_done(assignment)
		end
	end
end

function Game:on_cursor_moved()
	if not self.active then
		return
	end
	if not self.win or vim.api.nvim_get_current_win() ~= self.win then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(self.win)
	local line = cursor[1]
	local col = cursor[2] + 1
	local assignment = self.current_assignment
	if not assignment or assignment.done then
		return
	end
	local aline, acol = self:get_assignment_coords(assignment)
	if line == aline and col == acol then
		if not assignment.notified then
			assignment.notified = true
			local handler = assignment_types[assignment.type]
			local desc = handler and handler.description or ""
			if desc ~= "" then
				local message = string.format("Assignment <%s>: %s", assignment.type, desc)
				vim.notify(message, vim.log.levels.INFO, {
					title = "LearningGame assignment",
					timeout = 8000,
				})
			end
		end
	end
end

function Game:mark_assignment_done(assignment)
	assignment.done = true
	self.completed = self.completed + 1
	local handler = assignment_types[assignment.type]
	if handler and handler.cleanup then
		handler.cleanup(self, assignment)
	end
	self:clear_marker(assignment)
	self.current_assignment = nil
	self:update_status()
	if self.completed >= self.total_assignments then
		self:display_tip()
		self:finish(false)
	else
		self:spawn_next_assignment()
	end
end

function Game:next_assignment()
	return self.current_assignment
end

function Game:display_tip()
	if not self.active then
		return
	end
	local target = self:next_assignment()
	if not target then
		vim.api.nvim_echo({ { "LearningGame complete!", "Title" } }, false, {})
		return
	end
	local handler = assignment_types[target.type]
	local line, col = self:get_assignment_coords(target)
	local message =
		string.format("Next target (%s @ %d:%d): %s", target.type, line, col, handler and handler.description or "")
	vim.api.nvim_echo({ { message, "ModeMsg" } }, false, {})
end

function Game:update_status()
	if not self.win or not vim.api.nvim_win_is_valid(self.win) then
		return
	end
	local total = self.total_assignments
	local msg = string.format(" LearningGame %02d/%02d | Keys %d ", self.completed, total, self.key_count)
	vim.wo[self.win].statusline = msg .. "%=%l:%c"
end

function Game:finish(aborted)
	if not self.active then
		return
	end
	self.active = false
	if self.key_handler then
		vim.on_key(nil, KEY_NS)
		self.key_handler = nil
	end
	if self.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
		self.augroup = nil
	end
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		pcall(vim.api.nvim_win_close, self.win, true)
	end
	if vim.api.nvim_buf_is_valid(self.buf) then
		pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
	end
	local total_time = 0
	if self.start_time then
		total_time = (uv.hrtime() - self.start_time) / 1e9
	end
	local minutes = math.max(total_time / 60, 1e-6)
	local kpm = self.key_count / minutes
	if aborted then
		vim.notify(
			string.format("LearningGame aborted – %d/%d assignments solved", self.completed, self.total_assignments),
			vim.log.levels.WARN
		)
	else
		self:show_results_popup(total_time, kpm)
	end
	M.active_game = nil
end

local function split_time(total_sec)
	local minutes = math.floor(total_sec / 60)
	local seconds = math.floor(total_sec % 60)
	local millis = math.floor((total_sec % 1) * 1000)

	return minutes, seconds, millis
end

function Game:show_results_popup(total_time, kpm)
	local minutes, seconds, millis = split_time(total_time)
	local lines = {
		" LearningGame Complete ",
		string.rep("-", 26),
		string.format("Assignments   : %d/%d", self.completed, self.total_assignments),
		string.format("Time elapsed  : %02d:%02d.%03d", minutes, seconds, millis),
		string.format("Key presses   : %d", self.key_count),
		string.format("Keys per min  : %.1f", kpm),
		"",
		"Press q, <Esc> or <CR> to close",
	}
	local width, height = calc_popup_size(lines)
	local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
	local col = math.max(math.floor((vim.o.columns - width) / 2), 0)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "learninggame_results"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 200,
	})
	vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
	local function close_popup()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
		vim.keymap.set("n", key, close_popup, { buffer = buf, nowait = true, silent = true })
	end
end

assignment_types = {
	x = {
		description = "Move to this marker and delete it with `x`.",
		check = function(game, assignment)
			-- NOTE: Fixa en check så man inte kan radera raden för att komma vidare
			local char = game:get_assignment_char(assignment)
			return char == "."
		end,
		cleanup = function(game, assignment)
			local line, col = game:get_assignment_coords(assignment)

			local line_string = game:get_line(line)
			if #line_string == config.board.width - 1 then
				game:set_char(line, col, "..")
			end
		end,
	},
	r = {
		description = "Change this marker with `r` so it becomes a different character.",
		check = function(game, assignment)
			local char = game:get_assignment_char(assignment)
			return char ~= "r" and char ~= ""
		end,
		cleanup = function(game, assignment)
			local line, col = game:get_assignment_coords(assignment)
			game:set_char(line, col, ".")
		end,
	},
}

function M.start()
	if M.active_game and M.active_game.active then
		vim.notify("LearningGame is already running", vim.log.levels.WARN)
		return
	end
	local game = Game:new(config)
	M.active_game = game
	game:start()
end

function M.stop()
	if not M.active_game or not M.active_game.active then
		vim.notify("No LearningGame is running", vim.log.levels.INFO)
		return
	end
	M.active_game:finish(true)
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})
	if not M._commands_created then
		vim.api.nvim_set_hl(0, "LearningGameAssignment", { link = "IncSearch" })
		vim.api.nvim_create_user_command("LearningGameStart", function()
			M.start()
		end, { desc = "Start the LearningGame session" })
		vim.api.nvim_create_user_command("LearningGameStop", function()
			M.stop()
		end, { desc = "Stop the active LearningGame session" })
		M._commands_created = true
	end
end

M.setup()

return M
