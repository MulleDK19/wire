-- Memory Viewer by MulleDK19

if SERVER then
	AddCSLuaFile()
end

-- A for loop running over several ticks
local function MultiTickIteration(iterationStart, iterationEnd, step, perTick, interval, itFunc, endFunc)
	local id = "MultiTickIterationTimer" .. tostring(math.floor(SysTime() * 100000000))
	
	local done = false
	timer.Create(id, interval, 0, function()
		local iEnd = math.min(iterationStart + perTick - 1, iterationEnd)
		local lastI
		for i = iterationStart, iEnd, step do
			lastI = i
			local keepRunning, newI = itFunc(i)
			if newI then i = newI end
			
			if not keepRunning or i == iterationEnd then
				done = true
				break
			end
		end
		
		if done then
			timer.Remove(id)
			if endFunc then
				endFunc(lastI + 1)
			end
		else
			iterationStart = lastI + 1
		end
	end)
	
	return id
end

if CLIENT then
	CreateClientConVar("wire_memviewer_displaymode", 0, true, false)
	CreateClientConVar("wire_memviewer_cellwidth", 64, true, false)
	CreateClientConVar("wire_memviewer_cellheight", 24, true, false)
	CreateClientConVar("wire_memviewer_columns", 10, true, false)
	CreateClientConVar("wire_memviewer_fontsizemultiplier", 1.0, true, false)
	CreateClientConVar("wire_memviewer_hex", 0, true, false)
end

if SERVER then
	util.AddNetworkString("Wire.MemoryViewer.DeviceSize.Request")
	util.AddNetworkString("Wire.MemoryViewer.DeviceSize.Response")
	util.AddNetworkString("Wire.MemoryViewer.DeviceSize.Progress")
	util.AddNetworkString("Wire.MemoryViewer.MemorySnapshot.Request")
	util.AddNetworkString("Wire.MemoryViewer.MemorySnapshot.Response")
	util.AddNetworkString("Wire.MemoryViewer.SetMemory.Request")
	util.AddNetworkString("Wire.MemoryViewer.FillMemory.Request")
	util.AddNetworkString("Wire.MemoryViewer.FillMemory.Progress")
	util.AddNetworkString("Wire.MemoryViewer.FindMemory.Request")
	util.AddNetworkString("Wire.MemoryViewer.FindMemory.Response")
	util.AddNetworkString("Wire.MemoryViewer.FindMemory.Progress")
	
	net.Receive("Wire.MemoryViewer.DeviceSize.Request", function(len, ply)
		local entity = net.ReadEntity() -- The entity to count the memory for.
		function returnSize(size2)
			-- No memory
			net.Start("Wire.MemoryViewer.DeviceSize.Response")
				net.WriteEntity(entity)
				net.WriteInt(size2, 32)
			net.Send(ply)
		end
		
		if not WireLib.HasPorts(entity) then
			returnSize(0)
			return
		end
		
		if entity.VM then
			-- If CPU, just return the RAM size.
			returnSize(entity.VM.RAMSize)
		elseif not entity.ReadCell or not entity:ReadCell(0) then
			-- No memory
			returnSize(0)
		elseif entity:GetClass() == "gmod_wire_keyboard" then
			returnSize(256)
		elseif entity:GetClass() == "gmod_wire_extbus" then
			returnSize(entity.ControlDataSize)
		elseif entity:GetClass() == "gmod_wire_value" then
			returnSize(#entity.values)
		elseif entity:GetClass() == "gmod_wire_soundemitter" then
			returnSize(4)
		elseif entity:GetClass() == "gmod_wire_radio" then
			returnSize(entity.values)
		else
			-- Otherwise, since devices don't provide a way to retrieve their size (at least not universally), count the cells that can be changed.
			local deviceSize = 0
			local itStart = 0
			local itEnd = 1024 * 1024
			local step = 1024
			local perTick = 1024*16
			local interval = 0.1
			
			MultiTickIteration(itStart, itEnd, step, perTick, interval, function(i)
				local oldValue = entity:ReadCell(i) or 0
				entity:WriteCell(i, oldValue - 200) -- 200 is a randomly chosen value.
				local newValue = entity:ReadCell(i) or 0
				
				net.Start("Wire.MemoryViewer.DeviceSize.Progress")
				net.WriteEntity(entity)
				net.WriteInt(i, 32)
				net.Send(ply)
				
				if newValue ~= oldValue then
					-- The value at the address changed, the cell is valid.
					entity:WriteCell(i, oldValue) -- Restore value
					return true -- Keep iterating
				else
					return false -- We've gone beyond memory. Break iteration
				end
			end, function(start)
				-- At this point, since we've only checked each 1024th cell, we've gone way past the last valid memory cell.
				-- Find the last valid cell.
				for i = start, 0, -1 do
					local oldValue = entity:ReadCell(i) or 0
					entity:WriteCell(i, oldValue - 200) -- 200 is a randomly chosen value.
					local newValue = entity:ReadCell(i) or 0
					if newValue ~= oldValue then
						-- The value at the address changed, the cell is valid.
						entity:WriteCell(i, oldValue) -- Restore value
						break -- We're done
					else
						deviceSize = i
					end
				end
				
				-- Send the response.
				returnSize(deviceSize)
			end)
		end
	end)
	
	net.Receive("Wire.MemoryViewer.MemorySnapshot.Request", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local start = net.ReadInt(32)
		local size = net.ReadInt(32)
		
		net.Start("Wire.MemoryViewer.MemorySnapshot.Response")
			net.WriteEntity(entity)
			net.WriteInt(start, 32)
			net.WriteInt(size, 32)
			for i = start, start + size - 1 do
				local value = entity:ReadCell(i) or 0
				net.WriteFloat(value)
			end
		net.Send(ply)
	end)
	
	net.Receive("Wire.MemoryViewer.SetMemory.Request", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local memAddress = net.ReadInt(32)
		local value = net.ReadFloat()
		entity:WriteCell(memAddress, value)
	end)
	
	net.Receive("Wire.MemoryViewer.FillMemory.Request", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local start = net.ReadInt(32)
		local size = net.ReadInt(32)
		local value = net.ReadFloat()
		print("START: " .. start .. ", SIZE: " .. size .. ", VALUE: " .. value)
		local itStart = start
		local itEnd = start + size - 1
		local step = 1
		local perTick = 1024*16
		local interval = 0.1
		MultiTickIteration(itStart, itEnd, step, perTick, interval, function(i)
			entity:WriteCell(i, value)
			if (i % 1024*1) == 0 then
				net.Start("Wire.MemoryViewer.FillMemory.Progress")
					net.WriteEntity(entity)
					net.WriteFloat(i / (itEnd - itStart))
				net.Send(ply)
			end
			
			return true
		end, function(i)
			net.Start("Wire.MemoryViewer.FillMemory.Progress")
				net.WriteEntity(entity)
				net.WriteFloat(1)
			net.Send(ply)
		end)
	end)
	
	net.Receive("Wire.MemoryViewer.WriteMemory.Request", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local start = net.ReadInt(32)
		local size = net.ReadInt(32)
		local valueCount = net.ReadInt(32)
		local values = {}
		for i = 1, valueCount do
			values[i] = net.ReadFloat()
		end
		
		local valueI = 1
		local itStart = start
		local itEnd = start + size - 1
		local step = 1
		local perTick = 1024*16
		local interval = 0.1
		MultiTickIteration(itStart, itEnd, step, perTick, interval, function(i)
			local value = values[valueI]
			valueI = valueI + 1
			entity:WriteCell(i, value)
			if (i % 1024*1) == 0 then
				net.Start("Wire.MemoryViewer.WriteMemory.Progress")
					net.WriteEntity(entity)
					net.WriteFloat(i / (itEnd - itStart))
				net.Send(ply)
			end
			
			return true
		end, function(i)
			net.Start("Wire.MemoryViewer.WriteMemory.Progress")
				net.WriteEntity(entity)
				net.WriteFloat(1)
			net.Send(ply)
		end)
	end)
	
	net.Receive("Wire.MemoryViewer.FindMemory.Request", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local query = net.ReadString()
		local searchStart = net.ReadInt(32)
		local searchEnd = net.ReadInt(32)
		
		local elements = {}
		
		function searchError(err)
			net.Start("Wire.MemoryViewer.FindMemory.Response")
				net.WriteEntity(entity)
				net.WriteString(query)
				net.WriteString(err)
				net.WriteInt(-1, 32)
				net.WriteInt(0, 32)
			net.Send(ply)
		end
		
		local element = ""
		local function addCurrentElement(i)
			if not element or #element < 1 then
				return "Empty search element at column " .. i .. ".\n\nIf you intended to search for a comma, use its ASCII value 44 (Eg. \"Hello,44,World\")."
			end
			element = string.Trim(element)
			table.insert(elements, element)
			element = ""
			return nil
		end
		
		-- Parse
		for i = 1, #query do
			local char = query[i]
			if char == ',' then
				local err = addCurrentElement(i)
				if err then
					searchError(err)
					return
				end
			else
				element = element .. char
			end
		end
		local err = addCurrentElement()
		if err then
			searchError(err)
			return
		end
		
		local function getMemory(memAddress)
			return entity:ReadCell(memAddress) or 0
		end
		
		--Assign match functions
		local matchers = {}
		local function numberMatcher(memAddress, targetValue)
			local value = getMemory(memAddress)
			if value == targetValue then
				return 1
			elseif math.abs(value - targetValue) < 0.000001 then
				return 1
			end
			
			return nil
		end
		local function stringMatcher(memAddress, targetValue)
			local matchLength = 0
			local offset = -1
			for i = 1, #targetValue do
				offset = offset + 1
				local value = getMemory(memAddress + offset)
				if value == string.byte(targetValue, i) then
					matchLength = matchLength + 1
				else
					return nil
				end
			end
			
			return matchLength
		end
		
		for i = 1, #elements do
			local valueString = elements[i]
			local valueNumber = tonumber(valueString)
			if valueNumber then
				table.insert(matchers, {numberMatcher, valueNumber})
			else
				table.insert(matchers, {stringMatcher, valueString})
			end
		end
		
		local foundAt = -1
		local foundLength = 0
		local memAddress = searchStart
		--[[while memAddress <= searchEnd do
			foundLength = 0
			local memAddress2 = memAddress
			local found = true
			for i = 1, #matchers do
				local matcher = matchers[i]
				local matcherFunction = matcher[1]
				local matcherValue = matcher[2]
				local matchLength = matcherFunction(memAddress, matcherValue)
				if not matchLength then
					found = false
					memAddress = memAddress + 1 -- Advance search one cell
					break
				else
					memAddress = memAddress + matchLength -- Advance search the matched length
					foundLength = foundLength + matchLength
				end
			end
			
			if found then
				foundAt = memAddress2
				break
			end
		end]]
		
		MultiTickIteration(0, 999999999, 1, 4096, 0.1, function(i)
			if memAddress > searchEnd then return false end
			
			foundLength = 0
			local memAddress2 = memAddress
			local found = true
			for i2 = 1, #matchers do
				local matcher = matchers[i2]
				local matcherFunction = matcher[1]
				local matcherValue = matcher[2]
				local matchLength = matcherFunction(memAddress, matcherValue)
				if not matchLength then
					found = false
					memAddress = memAddress + 1 -- Advance search one cell
					break
				else
					memAddress = memAddress + matchLength -- Advance search the matched length
					foundLength = foundLength + matchLength
				end
			end
			
			if found then
				foundAt = memAddress2
				return false
			end
			
			if (memAddress2 % 1024*1) == 0 then
				net.Start("Wire.MemoryViewer.FindMemory.Progress")
					net.WriteEntity(entity)
					net.WriteFloat(memAddress / searchEnd)
				net.Send(ply)
			end
			
			return true
		end, function(i)
			net.Start("Wire.MemoryViewer.FindMemory.Response")
				net.WriteEntity(entity)
				net.WriteString(query)
				net.WriteString("")
				net.WriteInt(foundAt, 32)
				net.WriteInt(foundLength, 32)
			net.Send(ply)
		end)
	end)
else
	net.Receive("Wire.MemoryViewer.DeviceSize.Response", function(len, ply)
		local entity = net.ReadEntity()
		local deviceSize = net.ReadInt(32)
		
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnDeviceSizeReceived(deviceSize)
		end
	end)
	
	net.Receive("Wire.MemoryViewer.MemorySnapshot.Response", function(len, ply)
		local entity = net.ReadEntity()
		local start = net.ReadInt(32)
		local size = net.ReadInt(32)
		
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			if start ~= panel.MemoryView.MemoryStart then
				-- This snapshot is no longer relevant.
				panel.IsWaitingForMemorySnapshot = false
				return
			end
			
			local memory = {}
			for i = 0, size do
				memory[i] = net.ReadFloat()
			end
		
			panel:OnMemorySnapshotReceived(memory)
			panel.IsWaitingForMemorySnapshot = false
		end
	end)
	
	net.Receive("Wire.MemoryViewer.DeviceSize.Progress", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local progress = net.ReadInt(32)
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnDeviceSizeProgress(progress)
		end
	end)
	
	net.Receive("Wire.MemoryViewer.FillMemory.Progress", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local progress = net.ReadFloat()
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnFillMemoryProgress(progress)
		end
	end)
	
	net.Receive("Wire.MemoryViewer.WriteMemory.Progress", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local progress = net.ReadFloat()
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnWriteMemoryProgress(progress)
		end
	end)
	
	net.Receive("Wire.MemoryViewer.FindMemory.Response", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local query = net.ReadString()
		local searchError = net.ReadString()
		local foundAt = net.ReadInt(32)
		local foundLength = net.ReadInt(32)
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnMemoryFound(query, foundAt, foundLength)
			if searchError and #searchError > 0 then
				Derma_Message(searchError, "Error!")
			end
		end
	end)
	
	net.Receive("Wire.MemoryViewer.FindMemory.Progress", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) then return end
		local progress = net.ReadFloat()
		local panel = MemoryViewerPanelTables[entity]
		if panel then
			panel:OnFindMemoryProgress(progress)
		end
	end)
	
	-- Entity to memory viewer "bindings".
	MemoryViewerPanelTables = {}
end

include("memview.lua")

if CLIENT then
	local MVP = {}
	
	MVP.DeviceSize = 0
	MVP.LastFoundAt = -1 -- Last search address
	
	function MVP:Init()
		local cellWidth = math.max(4, GetConVar("wire_memviewer_cellwidth"):GetInt()) --64
		local cellHeight = math.max(4, GetConVar("wire_memviewer_cellheight"):GetInt()) --24
		local columnCount = math.max(4, GetConVar("wire_memviewer_columns"):GetInt()) --10
		
		self:SetTitle("Memory Viewer")
		self:SetWide(1000)
		self:SetTall(800)
		self:SetPos(150, 200)
		self:SetSizable(true)
		self:SetIcon("icon16/table_edit.png")
		self:Hide()
		
		self:InitializeStatusBar()
		self:InitializeMemoryView()
		
		self:InitProgressBox()
		
		self:InitializeMenuBar()
		
		self.MemorySnapshot = {}
		
		util.PrecacheSound("buttons/button11.wav")
		util.PrecacheSound("buttons/button9.wav")
	end
	
	function MVP:OnRemove()
		if self.Entity then
			MemoryViewerPanelTables[self.Entity] = nil
		end
	end
	
	function MVP:OnDeviceSizeReceived(deviceSize)
		self.DeviceSize = deviceSize
		self.MemoryView.DeviceSize = deviceSize
		self:ShowProgress()
		self.OverrideDeviceSizeViewMenuOption:SetText("Override device size: " .. deviceSize)
	end
	
	function MVP:OnMemorySnapshotReceived(memory)
		self.MemorySnapshot = memory
	end
	
	function MVP:OnDeviceSizeProgress(deviceSize)
		self:ShowProgress("Querying device size\n" .. deviceSize, -1)
	end
	
	function MVP:OnFillMemoryProgress(progress)
		if progress >= 1.0 then
			self:ShowProgress(nil, nil)
		else
			self:ShowProgress("Filling memory", progress)
		end
	end
	
	function MVP:OnWriteMemoryProgress(progress)
		if progress >= 1.0 then
			self:ShowProgress(nil, nil)
		else
			self:ShowProgress("Writing memory", progress)
		end
	end
	
	function MVP:OnMemoryFound(query, foundAt, foundLength)
		self:ShowProgress(nil, nil)
		self.IsSearching = false
		
		if not foundAt or foundAt < 0 then
			LocalPlayer():EmitSound("buttons/button11.wav")
			return
		end
		
		self.MemoryView:GoToAddress(foundAt)
		self.MemoryView:HighlightAddressesRange(foundAt, foundLength)
		LocalPlayer():EmitSound("buttons/button9.wav")
		self.LastFoundAt = foundAt
		
		if self.SearchBox and self.SearchBox.SearchStartLabel then
			self.SearchBox.SearchStartLabel:SetText("Search start address: " .. tostring((foundAt or 0) + 1));
			self.SearchBox.SearchStartLabel:SizeToContents()
		end
	end
	
	function MVP:OnFindMemoryProgress(progress)
		self:ShowProgress("Searching memory", progress)
	end
	
	-- Sets the entity we're currently reading the memory from.
	function MVP:SetEntity(entity)
		if not IsValid(entity) then
			if MemoryViewerPanelTables[self.Entity] then
				MemoryViewerPanelTables[self.Entity] = nil
			end
			self.Entity = nil
			return
		end
		
		self.Entity = entity
		MemoryViewerPanelTables[entity] = self
		
		-- Request the size of the device from server.
		net.Start("Wire.MemoryViewer.DeviceSize.Request")
			net.WriteEntity(entity)
			net.SendToServer()
		self:ShowProgress("Querying device size", -1)
	end
	
	function MVP:FillMemory(start, size, value)
		self:ShowProgress("Filling memory", 0)
		net.Start("Wire.MemoryViewer.FillMemory.Request")
			net.WriteEntity(self.Entity)
			net.WriteInt(start, 32)
			net.WriteInt(size, 32)
			net.WriteFloat(value)
		net.SendToServer()
	end
	
	function MVP:SetMemory(memAddress, value)
		if not memAddress or not value then return end
		if memAddress < 0 or memAddress >= self.DeviceSize then return end
		self.MemorySnapshot[memAddress - self.MemoryView.MemoryStart] = value
		net.Start("Wire.MemoryViewer.SetMemory.Request")
			net.WriteEntity(self.Entity)
			net.WriteInt(memAddress, 32)
			net.WriteFloat(value)
		net.SendToServer()
	end
	
	function MVP:WriteMemory(memAddress, values)
		self:ShowProgress("Writing memory", 0)
		if not memAddress or not values then return end
		--memoryViewer.MemorySnapshot[memAddress - memoryViewer.MemoryView.MemoryStart] = value
		net.Start("Wire.MemoryViewer.WriteMemory.Request")
			net.WriteEntity(memoryViewer.Entity)
			net.WriteInt(memAddress, 32)
			net.WriteInt(#values, 32)
			for i = 1, #values do
				net.WriteFloat(values[i])
			end
		net.SendToServer()
	end
	
	function MVP:InitializeMemoryView()
		local memoryViewer = self
		local memoryView = vgui.Create("MemoryViewPanel", self)
		self.MemoryView = memoryView
		self.MemorySnapshot = {}
		
		memoryView.LiveUpdate = true -- We want to see memory writes in real time.
		memoryView.DeviceSize = 0
		
		function memoryView:UpdateMemorySnapshot()
			if memoryViewer.IsWaitingForMemorySnapshot then return end
			memoryViewer.IsWaitingForMemorySnapshot = true
			net.Start("Wire.MemoryViewer.MemorySnapshot.Request")
			net.WriteEntity(memoryViewer.Entity)
			net.WriteInt(memoryViewer.MemoryView.MemoryStart, 32)
			net.WriteInt(memoryViewer.MemoryView.MemorySize, 32)
			net.SendToServer()
		end
		
		function memoryView:GetMemory(memAddress)
			return memoryViewer.MemorySnapshot[memAddress - memoryViewer.MemoryView.MemoryStart] or 0
		end
		
		function memoryView:SetMemory(memAddress, value)
			memoryViewer:SetMemory(memAddress, value)
		end
		
		function memoryView:FillMemory(memAddress, count, value)
			memoryViewer:FillMemory(memAddress, count, value)
		end
		
		function memoryView:IsMemoryAvailable()
			return memoryViewer.MemorySnapshot and #memoryViewer.MemorySnapshot > 0
		end
		
		function memoryView:InvalidateMemorySnapshot()
			memoryViewer.MemorySnapshot = {}
			do return end
			if not memoryViewer.MemorySnapshot then
				memoryViewer.MemorySnapshot = {}
			else
				table.Empty(memoryViewer.MemorySnapshot)
			end
		end
		
		memoryView.DisplayMode = GetConVar("wire_memviewer_displaymode"):GetInt()
		memoryView.DisplayHex = GetConVar("wire_memviewer_hex"):GetBool()
		memoryView.CellWidth = GetConVar("wire_memviewer_cellwidth"):GetInt()
		memoryView.CellHeight = GetConVar("wire_memviewer_cellheight"):GetInt()
		memoryView.ColumnCount = GetConVar("wire_memviewer_columns"):GetInt()
		memoryView:InitializeFonts(GetConVar("wire_memviewer_fontsizemultiplier"):GetFloat())
	end
	
	function MVP:InitializeStatusBar()
		local viewer = self
		local statusBar = vgui.Create("DPanel", self)
		self.StatusBar = statusBar
		statusBar:Dock(BOTTOM)
		function statusBar:Paint(w, h)
			surface.SetDrawColor(60, 60, 60, 255)
			surface.DrawRect(0, 0, w, h)
			
			local statusText = "Entity: " .. tostring(viewer.Entity) .. " | "
			if viewer.MemoryView.DeviceSize > -1 then
				statusText = statusText .. "Memory size: " .. tostring(viewer.MemoryView.DeviceSize)
			else
				statusText = statusText .. "Memory size: Querying..."
			end
			
			if viewer.MemoryView.HoverAddress > -1 then
				statusText = statusText .. " | Address: " .. tostring(viewer.MemoryView.HoverAddress)
			else
				statusText = statusText .. " | Address: ???"
			end
			
			local MemoryFillProgress = 0 -- TODO
			if MemoryFillProgress > 0 then
				statusText = statusText .. " | Filling memory: " .. MemoryFillProgress .. "%"
			end
			
			surface.SetFont("DermaDefault")
			local textW, textH = surface.GetTextSize(statusText)
			draw.DrawText(statusText, "DermaDefault", 8, (h / 2 - textH / 2) - 1, Color(255, 255, 255, 255), TEXT_ALIGN_LEFT)
		end
	end
	
	function MVP:InitProgressBox()
		local progressBox = vgui.Create("DFrame", self)
		progressBox:ShowCloseButton(false)
		self.ProgressBox = progressBox
		progressBox:SetSize(256,96)
		
		local progressBar = vgui.Create("DProgress", progressBox)
		self.ProgressBar = progressBar
		progressBar:Dock(FILL)
		progressBar:DockMargin(5, 35, 5, 5)
		function progressBox:Think()
			if progressBox:IsVisible() then
				progressBox:Center()
			end
		end
		
		local progressLabel = vgui.Create("DLabel", progressBox)
		self.ProgressLabel = progressLabel
		progressLabel:SetText("Please wait...")
		progressLabel:SizeToContents()
		progressLabel:SetPos(12, 32)
	end
	
	function MVP:InitializeMenuBar()
		local menuBar = vgui.Create("DMenuBar", self)
		self.MenuBar = menuBar
		menuBar:DockMargin(-3, -6, -3, 0)
		
		local memoryViewer = self
		
		-- EDIT MENU
		local editMenu = menuBar:AddMenu("Edit")
		local zeroMemoryOption = editMenu:AddOption("Zero all addresses...", function()
			Derma_Query("Are you sure you want to zero all addresses?", "Zero all addresses", "Yes", function()
				memoryViewer:FillMemory(0, memoryViewer.MemoryView.DeviceSize, 0)
			end, "No")
		end)
		zeroMemoryOption:SetIcon("icon16/page_white_code.png")
		local fillMemoryOption = editMenu:AddOption("Fill all addresses...", function()
			Derma_StringRequest("Fill all addresses", "Enter the value to fill all addresses with", "112", function(text) -- 112 is the ZCPU NOP instruction
				if string.len(text) > 0 then
					local value = tonumber(text)
					if not value then
						value = string.byte(text, 1)
					end
					
					if value then
						memoryViewer:FillMemory(0, memoryViewer.MemoryView.DeviceSize, value)
					end
				end
			end)
		end)
		fillMemoryOption:SetIcon("icon16/page_white_code_red.png")
		
		editMenu:AddSpacer()
		
		local editFindOption = editMenu:AddOption("Search", function() self:ShowSearchBox() end)
		editFindOption:SetIcon("icon16/find.png")
		-- EDIT MENU
		
		-- VIEW MENU
		local viewMenu = menuBar:AddMenu("View")
		-- Because sub menus are broken..
		local dmOpt1,dmOpt2,dmOpt3
		dmOpt1 = viewMenu:AddOption("Display mode: Floating point", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(0)
			memoryViewer.MemoryView.DisplayMode = 0
			dmOpt1:SetChecked(true)
			dmOpt2:SetChecked(false)
			dmOpt3:SetChecked(false)
		end)
		dmOpt2 = viewMenu:AddOption("Display mode: Alphanumeric", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(1)
			memoryViewer.MemoryView.DisplayMode = 1
			dmOpt1:SetChecked(false)
			dmOpt2:SetChecked(true)
			dmOpt3:SetChecked(false)
		end)
		dmOpt3 = viewMenu:AddOption("Display mode: Mixed", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(2)
			memoryViewer.MemoryView.DisplayMode = 2
			dmOpt1:SetChecked(false)
			dmOpt2:SetChecked(false)
			dmOpt3:SetChecked(true)
		end)
		dmOpt1:SetIsCheckable(false)
		dmOpt2:SetIsCheckable(false)
		dmOpt3:SetIsCheckable(false)
		local dm = GetConVar("wire_memviewer_displaymode"):GetInt()
		if dm == 0 then
			dmOpt1:SetChecked(true)
		elseif dm == 1 then
			dmOpt2:SetChecked(true)
		else
			dmOpt3:SetChecked(true)
		end
		
		local displayHexOption
		displayHexOption = viewMenu:AddOption("Display numbers in hexadecimal", function()
			local value = not memoryViewer.MemoryView.DisplayHex
			GetConVar("wire_memviewer_hex"):SetBool(value)
			memoryViewer.MemoryView.DisplayHex = value
			displayHexOption:SetChecked(value)
		end)
		displayHexOption:SetIsCheckable(false)
		displayHexOption:SetChecked(GetConVar("wire_memviewer_hex"):GetBool())
		
		
		viewMenu:AddSpacer()
		
		local opt3
		opt3 = viewMenu:AddOption("Column width: 64", function()
			Derma_StringRequest("Set column width", "Enter the new column width", tostring(GetConVar("wire_memviewer_cellwidth"):GetInt()), function(text)
				local width = tonumber(text) or 64
				opt3:SetText("Column width: " .. width)
				GetConVar("wire_memviewer_cellwidth"):SetInt(width)
				memoryViewer.MemoryView.CellWidth = width
			end)
		end)
		opt3:SetText("Column width: " .. GetConVar("wire_memviewer_cellwidth"):GetInt())
		opt3:SetIcon("icon16/arrow_right.png")
		local opt3
		opt4 = viewMenu:AddOption("Row height: 64", function()
			Derma_StringRequest("Set row height", "Enter the new row height", tostring(GetConVar("wire_memviewer_cellheight"):GetInt()), function(text)
				local height = tonumber(text) or 24
				opt4:SetText("Row height: " .. height)
				GetConVar("wire_memviewer_cellheight"):SetInt(height)
				memoryViewer.MemoryView.CellHeight = height
			end)
		end)
		opt4:SetText("Row height: " .. GetConVar("wire_memviewer_cellheight"):GetInt())
		opt4:SetIcon("icon16/arrow_down.png")
		local opt5
		opt5 = viewMenu:AddOption("Columns: 64", function()
			Derma_StringRequest("Set columns", "Enter the new number of columns", tostring(GetConVar("wire_memviewer_columns"):GetInt()), function(text)
				local height = tonumber(text) or 24
				opt5:SetText("Columns: " .. height)
				GetConVar("wire_memviewer_columns"):SetInt(height)
				memoryViewer.MemoryView.ColumnCount = height
			end)
		end)
		opt5:SetText("Columns: " .. GetConVar("wire_memviewer_columns"):GetInt())
		opt5:SetIcon("icon16/application_view_columns.png")
		
		local opt6
		opt6 = viewMenu:AddOption("Font size multiplier", function()
			Derma_StringRequest("Set font size multiplier", "Enter the new font size multiplier", tostring(GetConVar("wire_memviewer_fontsizemultiplier"):GetFloat()), function(text)
				local fontSizeMultiplier = tonumber(text) or 1.0
				opt6:SetText("Font size multiplier: " .. fontSizeMultiplier)
				GetConVar("wire_memviewer_fontsizemultiplier"):SetFloat(fontSizeMultiplier)
				memoryViewer.MemoryView:InitializeFonts(fontSizeMultiplier)
			end)
		end)
		opt6:SetText("Font size multiplier: " .. GetConVar("wire_memviewer_fontsizemultiplier"):GetInt())
		opt6:SetIcon("icon16/application_view_columns.png")
		
		viewMenu:AddSpacer()
		
		local viewGoToOption = viewMenu:AddOption("Go to address...", function()
			Derma_StringRequest("Go to address", "Enter the address to go to", "0", function(text)
				local memAddress = tonumber(text)
				if memAddress then
					memoryViewer.MemoryView:GoToAddress(memAddress)
				end
			end)
		end)
		
		viewMenu:AddSpacer()
		local overrideDeviceSizeViewMenuOption
		overrideDeviceSizeViewMenuOption = viewMenu:AddOption("Override device size", function()
			Derma_StringRequest("Override device size", "Enter the device size", tostring(memoryViewer.DeviceSize), function(text)
				local value = tonumber(text)
				if not value then value = 0 end
				value = math.floor(value)
				if value > 0 then
					memoryViewer:OnDeviceSizeReceived(value)
				else
					-- Request the size of the device from server.
					net.Start("Wire.MemoryViewer.DeviceSize.Request")
						net.WriteEntity(memoryViewer.Entity)
						net.SendToServer()
					self:ShowProgress("Querying device size", -1)
				end
			end)
		end)
		overrideDeviceSizeViewMenuOption:SetText("Override device size: " .. memoryViewer.DeviceSize)
		self.OverrideDeviceSizeViewMenuOption = overrideDeviceSizeViewMenuOption
		-- VIEW MENU
	end
	
	function MVP:ShowProgress(text, progress)
		if not text or not progress then
			self.ProgressBox:Hide()
			return
		end
		
		self.ProgressLabel:SetText(text .. "...")
		self.ProgressLabel:SizeToContents()
		
		if progress >= 0.0 then
			self.ProgressBar:SetFraction(progress)
			self.ProgressBar:Show()
			self.ProgressLabel:SetPos(12, 32)
		else
			self.ProgressBar:Hide()
			self.ProgressLabel:Center()
		end
		
		self.ProgressBox:Show()
		self.ProgressBox:Center()
	end
	
	function MVP:Find(query, start)
		if self.IsSearching then return end
		if not query then return end
		local memoryViewer = self
		
		query = string.Trim(query)
		if #query < 1 then return end
		start = start or 0
		
		self:ShowProgress("Searching memory", 0)
		self.IsSearching = true
		net.Start("Wire.MemoryViewer.FindMemory.Request")
			net.WriteEntity(self.Entity)
			net.WriteString(query)
			net.WriteInt(start, 32)
			net.WriteInt(memoryViewer.DeviceSize - 1, 32)
		net.SendToServer()
	end
	
	function MVP:ShowSearchBox()
		local memoryViewer = self
		
		local window = vgui.Create("DFrame")
		window:SetTitle("Search")
		window:SetSize(386, 96)
		window:Center()
		window:Show()
		window:MakePopup()
		
		function window:OnRemove()
			self.SearchBox = nil
		end
		
		self.SearchBox = window
		
		local posX, posY = self:GetPos()
		window:SetPos(posX + self:GetWide() - window:GetWide(), posY - window:GetTall() - 4)
		
		local findButton = vgui.Create("DButton", window)
		findButton:SetText("Find First")
		findButton:SetSize(64, 22)
		findButton:AlignTop(32)
		findButton:AlignRight(12)
		
		local findNextButton = vgui.Create("DButton", window)
		findNextButton:SetText("Find Next")
		findNextButton:SetSize(64, 22)
		findNextButton:AlignTop(32+22+8)
		findNextButton:AlignRight(12)
		
		local textBox = vgui.Create("DTextEntry", window)
		textBox:SetText("")
		textBox:SetSize(386-12-12-64-8, 22)
		textBox:SizeToContents()
		textBox:AlignTop(32)
		textBox:AlignLeft(12)
		textBox:SetToolTip("Example: 3.14,19,F,42,Hello,0")
		
		local label = vgui.Create("DLabel", window)
		label:AlignLeft(16)
		label:AlignBottom(8)
		label:SetText("Search start address: " .. tostring((self.LastFoundAt or 0) + 1))
		label:SizeToContents()
		self.SearchBox.SearchStartLabel = label
		
		function findButton:DoClick()
			label:SetText("Search start address: 0")
			memoryViewer.LastFoundAt = -1
			memoryViewer:Find(textBox:GetValue())
		end
		
		function findNextButton:DoClick()
			memoryViewer:Find(textBox:GetValue(), memoryViewer.LastFoundAt + 1)
		end
	end
	
	vgui.Register("MemoryViewerPanel", MVP, "DFrame")
end