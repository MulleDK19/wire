-- Memory View by MulleDK19

if SERVER then
	AddCSLuaFile()
end

if CLIENT then
	local MVP = {}
	
	MVP.DeviceSize = -1 -- The available number of memory cells.
	MVP.MemoryStart = 0 -- The address of the first memory cell being displayed.
	MVP.MemorySize = 0 -- The number of memory cells being displayed in the view.
	
	MVP.ColumnCount = 10 -- Number of columns to show per row.
	MVP.CellWidth = 64
	MVP.CellHeight = 24
	MVP.DisplayMode = 0 -- 0 = Floating point, 1 = Alphanumeri, 2 = Mixed
	MVP.DisplayHex = false -- Display numbers in hex when applicable.
	
	MVP.LastScrollValue = -1 -- The last value of the vertical scroll bar.
	
	MVP.HoverAddress = -1 -- The address the cursor is currently hovering over, or -1 if not hovering over a valid memory cell.
	
	MVP.Fonts = {}
	
	MVP.LastUpdateTime = SysTime() -- Last time we took a memory snapshot
	MVP.LiveUpdate = false -- Whether to update all the time, or only when the view has been scrolled or resized.
	MVP.LiveUpdateInterval = 0.1 -- The interval for updating.
	MVP.NeedsUpdating = false -- If not LiveUpdate, this indicates that we need to update.
	
	MVP.LastScrollTime = SysTime()
	MVP.IsWaitingForScrollStop = false
	
	MVP.CurrentEditAddress = -1 -- The address we're about to edit.
	
	function MVP:Init()
		self:DockMargin(0, 6, 0, 0)
		self:Dock(FILL)
		
		self:InitializeFonts(1.0)
		
		-- Create child controls
		local tmp = vgui.Create("DVScrollBar", self)
		tmp:Dock(RIGHT)
		tmp:DockMargin(0,0,0,0)
		tmp:SetWide(20)
		tmp:SetScroll(0)
		self.ScrollBar = tmp
		
		self:InitEditBox()
	end
	
	function MVP:InitializeFonts(fontSizeMultiplier)
		surface.CreateFont("MemViewer_AddressCell", {
			font = "Calibri",
			extended = true,
			size = 20 * fontSizeMultiplier,
			weight = 800,
			blursize = 0,
			scanlines = 0,
			antialias = true,
			underline = false,
			italic = false,
			strikeout = false,
			symbol = false,
			rotary = false,
			shadow = false,
			additive = false,
			outline = false,
		})
		surface.CreateFont("MemViewer_MemoryCell", {
			font = "Calibri",
			extended = true,
			size = 20 * fontSizeMultiplier,
			weight = 0,
			blursize = 0,
			scanlines = 0,
			antialias = true,
			underline = false,
			italic = false,
			strikeout = false,
			symbol = false,
			rotary = false,
			shadow = false,
			additive = false,
			outline = false,
		})
		
		self.Fonts["AddressCell"] = "MemViewer_AddressCell"
		self.Fonts["MemoryCell"] = "MemViewer_MemoryCell"
	end
	
	function MVP:InitEditBox()
		local memoryViewer = self
		local editBox = vgui.Create("DTextEntry", self)
		editBox:Hide()
		editBox:SetFont(self.Fonts["MemoryCell"])
		self.EditBox = editBox
		
		function editBox:Paint()
			surface.SetDrawColor(50, 50, 50, 255)
			surface.DrawRect(0, 0, self:GetWide(), self:GetTall())
			-- Ugh, why does this shit not have an X, Y offset? >.>
			self:DrawTextEntryText(Color(255, 255, 255), Color(30, 130, 255), Color(255, 255, 255))
		end
		
		function editBox:OnEnter()
			if memoryViewer.CurrentEditAddress < 0 then return end
			
			local text = self:GetValue()
			if text and string.len(text) > 0 then
				local value = tonumber(text)
				if value then
					memoryViewer:SetMemory(memoryViewer.CurrentEditAddress, value)
				else
					if string.Left(text, 2) == "0x" then
						memoryViewer:SetMemory(memoryViewer.CurrentEditAddress, tonumber(string.sub(text, 2), 16))
					else
						memoryViewer:SetMemory(memoryViewer.CurrentEditAddress, string.byte(text, 1))
					end
				end
			end
			
			self:Hide()
			memoryViewer.CurrentEditAddress = -1
		end
	end
	
	function MVP:OnMousePressed(keyCode)
		local editBox = self.EditBox
		
		if keyCode == MOUSE_LEFT then
			editBox:Hide()
			editBox:KillFocus()
			
			local address = self.HoverAddress
			if address < 0 then return end
			if GetConVar("wire_memviewer_readonly"):GetBool() then
				LocalPlayer():EmitSound("buttons/button11.wav")
				return
			end
			
			local value = self:GetMemory(address)
			if not value then
				return
			end
			
			self.CurrentEditAddress = address
			
			local cellWidth = self.CellWidth
			local cellHeight = self.CellHeight
		
			local x, y = self:CursorPos()
			x = math.floor(x / cellWidth) * cellWidth
			y = math.floor(y / cellHeight) * cellHeight
			editBox:SetPos(x, y)
			editBox:SetValue(self:GetNumberDisplayString(value))
			editBox:SetText(self:GetNumberDisplayString(value))
			editBox:SetSize(cellWidth, cellHeight)
			editBox:Show()
			editBox:SelectAll() -- fix-me: Ugh. Pressing a modifier key will deselect everything after using this call, so you can't type upper case letters. Works fine with Ctrl+A.
			editBox:RequestFocus()
		else
			if not editBox:IsVisible() then
				local address = self.HoverAddress
				if address < 0 then return end
				
				local menu = DermaMenu()
				local opt = menu:AddOption("Write string", function()
					Derma_StringRequest("Write string", "Enter the string to write, beginning at address " .. address, "Hello World", function(text)
						local textLen = string.len(text)
						for i = 0, textLen - 1 do
							local charValue = string.byte(text, i+1)
							self:SetMemory(address+i,charValue)
						end
						self:SetMemory(address+textLen,0) -- Zero terminate
					end)
				end)
				opt:SetIcon("icon16/font_go.png")
				menu:AddOption("Fill memory", function()
					Derma_StringRequest("Write string", "How many addresses do you wish to fill?", "100", function(text1)
						Derma_StringRequest("Write string", "Which value do you wish to fill them with?", "F", function(text2)
							local count = tonumber(text1) or 0
							local value = tonumber(text2)
							if not value then
								value = string.byte(text2, 1)
							end
							if count > 0 then
								self:FillMemory(address, count, value)
							end
						end)
					end)
				end)
				menu:Open()
			end

			editBox:Hide()
			editBox:KillFocus()
		end
	end
	
	function MVP:OnMouseWheeled(scrollDelta)
		local scroll = self.ScrollBar:GetScroll()
		local rowsPerScroll = 10
		self.ScrollBar:SetScroll(scroll - (scrollDelta * self.ColumnCount * rowsPerScroll))
	end
	
	-- Should be overriden
	function MVP:UpdateMemorySnapshot()
		error("FUNCTION NOT OVERRIDEN")
	end
	
	-- Should be overriden
	function MVP:GetMemory(memAddress)
		error("FUNCTION NOT OVERRIDEN")
	end
	
	-- Should be overriden
	function MVP:SetMemory(memAddress, value)
		error("FUNCTION NOT OVERRIDEN")
	end
	
	-- Should be overriden
	function MVP:FillMemory(memAddress, count, value)
		error("FUNCTION NOT OVERRIDEN")
	end
	
	-- Should be overriden
	function MVP:IsMemoryAvailable()
		error("FUNCTION NOT OVERRIDEN")
	end
	
	-- Should be overriden
	function MVP:InvalidateMemorySnapshot()
		error("FUNCTION NOT OVERRIDEN")
	end
	
	function MVP:GoToAddress(memAddress)
		-- Only scroll if the address is outside the current view.
		local startAddress = math.floor(self.DeviceSize * (self.ScrollBar:GetScroll() / self.DeviceSize))
		local endAddress = startAddress + self.MemorySize
		local shouldScroll = memAddress < startAddress or memAddress > endAddress
		
		if shouldScroll then
			local jumpAddress = memAddress
			jumpAddress = jumpAddress - self.ColumnCount * 5
			if jumpAddress < 0 then
				jumpAddress = 0
			end
			
			self.ScrollBar:SetScroll(jumpAddress)
		end
		
		self:HighlightAddresses(memAddress)
	end
	
	function MVP:HighlightAddressesRange(memAddress, length)
		local addresses = {}
		for i = 0, length - 1 do
			table.insert(addresses, memAddress + i)
		end
		
		self:HighlightAddresses(addresses)
	end
	
	function MVP:HighlightAddresses(memAddress)
		timer.Remove("Wire.MemoryViewer.Timer.HighlightAddress")
		if type(memAddress) == "number" then
			self.HighlightedMemoryAddresses = {}
			self.HighlightedMemoryAddresses[memAddress] = true
		else
			self.HighlightedMemoryAddresses = {}
			for _, addr in pairs(memAddress) do
				self.HighlightedMemoryAddresses[addr] = true
			end
		end
		self.ShouldHighlightAddress = true
		local it = 0
		local flickersPerSecond = 15
		local seconds = 1.5
		local count = flickersPerSecond * seconds
		timer.Create("Wire.MemoryViewer.Timer.HighlightAddress", 1 / flickersPerSecond, count, function()
			self.ShouldHighlightAddress = (it % 2) == 0
			it = it + 1
			if it == count then
				self.HighlightedMemoryAddresses = nil
				self.ShouldHighlightAddress = false
			end
		end)
	end
	
	function MVP:Think()
		local sysTime = SysTime()
		
		local scroll = self.ScrollBar:GetScroll()
		if scroll ~= self.LastScrollValue then
			self.LastScrollValue = scroll
			self:InvalidateMemorySnapshot()
			
			self.LastScrollTime = sysTime
			self.IsWaitingForScrollStop = true
			
			self.EditBox:Hide()
			self.EditBox:KillFocus()
		end
		
		if self.IsWaitingForScrollStop then
			if sysTime > self.LastScrollTime + self.LiveUpdateInterval then
				self.IsWaitingForScrollStop = false
				
				if not self.LiveUpdate then
					self.NeedsUpdating = true
				end
			end
		end
		
		-- We never update while scrolling.
		if not self.IsWaitingForScrollStop then
			if self.LiveUpdate then
				if sysTime > self.LastUpdateTime + self.LiveUpdateInterval then
					self:UpdateMemorySnapshot()
					self.LastUpdateTime = sysTime
				end
			else
				if self.NeedsUpdating then
					self:UpdateMemorySnapshot()
					self.NeedsUpdating = false
				end
			end
		end
	end
	
	function MVP:GetNumberDisplayString(mem)
		if not self.DisplayHex then
			return tostring(mem)
		end
		
		if (mem % 1) == 0 then
			return tostring(string.format("0x%x", mem))
		else
			return tostring(mem)
		end
	end
	
	function MVP:GetCharDisplayString(mem)
		local suc, char
		if mem == 0 then
			char = "\\0"
			suc = true
		elseif mem == 9 then
			char = "\\t"
			suc = true
		else
			suc, char = pcall(string.char, mem)
		end
		
		if suc then
			return "'" .. char .. "'"
		else
			return nil
		end
	end
	
	-- Given a number, returns how that number should be displayed in the memory view.
	function MVP:GetDisplayString(mem)
		local displayMode = self.DisplayMode
		if displayMode == 0 then
			return self:GetNumberDisplayString(mem)
		elseif displayMode == 1 then
			return self:GetCharDisplayString(mem) or "??"
		elseif displayMode == 2 then
			local charDisplay = self:GetCharDisplayString(mem)
			if charDisplay then
				return self:GetNumberDisplayString(mem) .. " " .. charDisplay
			else
				return self:GetNumberDisplayString(mem) .. " ??"
			end
		end
	end
	
	function MVP:Paint(w, h)
		w = w - 20 -- Subtract the width of the vertical scroll bar
		
		local sysTime = SysTime()
		local cellWidth = self.CellWidth
		local cellHeight = self.CellHeight
		local scrollBar = self.ScrollBar
		
		self.HoverAddress = -1
		local horizontalCellCount = 1 + self.ColumnCount --math.floor(w / cellWidth)
		local verticalCellCount = math.floor(h / cellHeight)
		
		local deviceSize = self.DeviceSize
		if deviceSize < 0 then
			draw.DrawText("Querying memory, please wait...", self.Fonts["AddressCell"], 8, 8, Color(255, 255, 255, 255), TEXT_ALIGN_LEFT)
			return
		elseif deviceSize == 0 then
			draw.DrawText("This device has no memory.", self.Fonts["AddressCell"], 8, 8, Color(255, 255, 255, 255), TEXT_ALIGN_LEFT)
			return
		end
		
		local endAddress = deviceSize
		
		scrollBar:SetUp((horizontalCellCount-1) * (verticalCellCount-1), deviceSize + 64)
		
		local scroll = scrollBar:GetScroll()
		local startAddress = math.floor(endAddress * (scroll / deviceSize))
		startAddress = math.floor(startAddress / 10) * 10
		self.MemoryStart = startAddress
		self.MemorySize = math.min((horizontalCellCount-1) * (verticalCellCount-1), deviceSize - startAddress)
		
		local currentAddress = startAddress - 1
		
		for y = 0, verticalCellCount-1 do
			for x = 0, horizontalCellCount-1 do
				local r, g, b
				if (y % 2) == 0 then
					if (x % 2) == 0 then
						r = 255; g = 255; b = 255
					else
						r = 225; g = 225; b = 225
					end
				else
					if (x % 2) == 0 then
						r = 200; g = 200; b = 200
					else
						r = 175; g = 175; b = 175
					end
				end
				
				if x == 0 or y == 0 then
					r = r - 150; g = g - 150; b = b - 150
				else
					r = r - 50; g = g - 50; b = b - 50
				end
				
				local cursorPosX, cursorPosY = self:CursorPos()
				
				local cellX = x * cellWidth
				local cellY = y * cellHeight
				local isCursorOver = false
				local shouldHighlight = false
				if (cursorPosX >= cellX and cursorPosX <= cellX + cellWidth) and
				   (cursorPosY >= cellY and cursorPosY <= cellY + cellHeight) then
				   isCursorOver = true
				end
				
				if (cursorPosX >= 0 and cursorPosX <= w and cursorPosY >= 0 and cursorPosY <= h) and
				   ((x == 0 and cursorPosY >= cellY and cursorPosY <= cellY + cellHeight) or
				   (y == 0 and cursorPosX >= cellX and cursorPosX <= cellX + cellWidth)) then
					shouldHighlight = true
				end
				
				if isCursorOver then
					if x ~= 0 and y ~= 0 then
						b = b + 50
					else
						self.HoverAddress = -1
					end
				end
				
				if shouldHighlight then
					r = r + 70; g = g + 100; b = b + 70
				end
				
				local cellText
				local cellTextColor
				if x == 0 and y == 0 then
					cellText = "---"
					cellTextColor = Color(0, 0, 0, 255)
				elseif x == 0 then
					local visualAddress = startAddress + ((horizontalCellCount-1) * (y - 1))
					cellText = tostring(visualAddress)
					if not shouldHighlight then
						cellTextColor = Color(255, 255, 255, 255)
					else
						cellTextColor = Color(0, 0, 0, 255)
					end
				elseif y == 0 then
					local visualAddress = (-1 + y + x)
					cellText = tostring(visualAddress)
					if not shouldHighlight then
						cellTextColor = Color(255, 255, 255, 255)
					else
						cellTextColor = Color(0, 0, 0, 255)
					end
				else
					currentAddress = currentAddress + 1
					if self:IsMemoryAvailable() then
						local mem = self:GetMemory(currentAddress)
						if not mem or currentAddress >= deviceSize then
							cellText = ""
							cellTextColor = Color(150, 25, 25, 255)
							r = r + 1000
						else
							cellText = self:GetDisplayString(mem)
							cellTextColor = Color(0, 0, 0, 255)
						end
					else
						if currentAddress >= deviceSize then
							cellText = ""
							cellTextColor = Color(150, 25, 25, 255)
							r = r + 1000
						else
							cellText = "###"
							cellTextColor = Color(150, 150, 25, 255)
							r = r + 50
							g = g + 50
						end
					end
					
					if isCursorOver then
						self.HoverAddress = currentAddress
					end
				end
				
				local font
				if x == 0 or y == 0 then
					font = self.Fonts["AddressCell"]
				else
					font = self.Fonts["MemoryCell"]
				end
				
				if x ~= 0 and y ~= 0 and self.ShouldHighlightAddress and self.HighlightedMemoryAddresses[currentAddress] then
					r = r + 100
					b = b + 100
				end
				
				surface.SetDrawColor(r, g, b, 255)
				surface.DrawRect(cellX, cellY, cellWidth, cellHeight)
				
				if #cellText > 7 then
					cellText = string.sub(cellText, 1, 7)
				end
				
				surface.SetFont(font)
				local textW, textH = surface.GetTextSize(cellText)
				draw.DrawText(cellText, font, cellX + cellWidth / 2 - textW / 2, cellY + cellHeight / 2 - textH / 2, cellTextColor, TEXT_ALIGN_LEFT)
			end
		end
		
		--draw.DrawText(tostring(MemoryStart) .. " " .. tostring(MemorySize), self.Fonts["AddressCell"], 0, 0, Color(0,0,0,255), TEXT_ALIGN_LEFT)
	end
	
	vgui.Register("MemoryViewPanel", MVP, "DPanel")
end