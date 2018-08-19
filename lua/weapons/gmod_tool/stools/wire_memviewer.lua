TOOL.Category		= "Tools"
TOOL.Name			= "Memory Viewer"
TOOL.Command		= nil
TOOL.ConfigName		= ""
TOOL.Tab			= "Wire"

if CLIENT then
	language.Add( "Tool.wire_memviewer.name", "Memory Viewer" )
	language.Add( "Tool.wire_memviewer.desc", "Views and modifies memory" )
	language.Add( "Tool.wire_memviewer.left", "Open the viewer for device" )
	language.Add( "Tool.wire_memviewer.right", "PLACEHOLDER" )
	language.Add( "Tool.wire_memviewer.reload", "PLACEHOLDER" )
	language.Add( "Tool_wire_memviewer_readonly", "Readonly" )
	TOOL.Information = { "left", "right", "reload" }
end

util.PrecacheSound("buttons/button11.wav")

if SERVER then
	util.AddNetworkString("WireMemViewerSetAddress")
	util.AddNetworkString("WireMemViewerRequestMemory")
	util.AddNetworkString("WireMemViewerRequestMemoryResponse")
	util.AddNetworkString("WireMemViewerRequestDeviceSize")
	util.AddNetworkString("WireMemViewerRequestDeviceSizeResponse")
	util.AddNetworkString("WireMemViewerFillMemory")
	util.AddNetworkString("WireMemViewerFillMemoryProgress")
	
	net.Receive("WireMemViewerSetAddress", function(len, ply)
		local entity = net.ReadEntity()
		local address = net.ReadInt(32)
		local value = net.ReadFloat()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		local canTool = true -- TODO    local canTool = hook.Run("CanTool", ply, util.GetPlayerTrace(ply), "wire_memviewer")
		if not canTool then return end
		print("SET ADDRESS " .. address .. " of " .. tostring(entity) .. " to " .. value)
		entity:WriteCell(address, value)
	end)
	
	net.Receive("WireMemViewerRequestMemory", function(len, ply)
		local entity = net.ReadEntity()
		local start = net.ReadInt(32)
		local size = net.ReadInt(16)
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		
		net.Start("WireMemViewerRequestMemoryResponse")
		net.WriteEntity(entity)
		net.WriteInt(start, 32)
		net.WriteInt(size, 16)
		for i = 0, size - 1 do
			local address = start + i
			local value = entity:ReadCell(address) or 0
			net.WriteFloat(value)
		end
		net.Send(ply)
	end)
	
	--[[net.Receive("WireMemViewerRequestDeviceSize", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		
		local deviceSize = 0
		if entity.VM then
			deviceSize = entity.VM.RAMSize
		else
			local gateAction = entity.action
			local gate = GateActions[gateAction]
			if gate and gate.LatchStore then
				deviceSize = #gate.LatchStore
			else
				-- Most devices don't seem to contain a size (not one that can be retrieved universally anyway), so we have to count the cells that can be changed.
				deviceSize = 0
				for i = 0, 262144-1 do
					local oldValue = entity:ReadCell(i) or 0
					entity:WriteCell(i, oldValue - 200) -- 200 is random.
					local value = entity:ReadCell(i)
					if value ~= oldValue then
						-- It changed, so the device has a memory cell at this offset.
						deviceSize = deviceSize + 1
						entity:WriteCell(i, oldValue) -- Restore value
					end
				end
			end
		end
		
		net.Start("WireMemViewerRequestDeviceSizeResponse")
		net.WriteEntity(entity)
		net.WriteInt(deviceSize, 32)
		net.Send(ply)
	end)]]
	
	local function MultiTickIteration(iterationStart, iterationEnd, perTick, interval, itFunc, endFunc)
		local id = "MultiTickIterationTimer" .. tostring(math.floor(SysTime() * 1000000))
		
		local done = false
		timer.Create(id, interval, 0, function()
			local iEnd = math.min(iterationStart + perTick - 1, iterationEnd)
			local lastI
			for i = iterationStart, iEnd do
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
					endFunc()
				end
			else
				iterationStart = lastI + 1
			end
		end)
		
		return id
	end
	
	net.Receive("WireMemViewerRequestDeviceSize", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		
		local deviceSize = 0
		local iterationStart = 0
		local iterationEnd = 1024*1024-1
		
		if entity.VM then
			deviceSize = entity.VM.RAMSize
			net.Start("WireMemViewerRequestDeviceSizeResponse")
			net.WriteEntity(entity)
			net.WriteInt(deviceSize, 32)
			net.Send(ply)
		else
			local readsPerIteration = 1024
			timer.Create("WireMemViewerRequestDeviceSizeTimer", 0.01, 0, function()
				local done = false
				-- Most devices don't seem to contain a size (not one that can be retrieved universally anyway), so we have to count the cells that can be changed.
				local nextIterationStart = 0
				for i = iterationStart, iterationEnd do
					nextIterationStart = i + 1
					local oldValue = entity:ReadCell(i) or 0
					entity:WriteCell(i, oldValue - 200) -- 200 is random.
					local value = entity:ReadCell(i) or 0
					if value ~= oldValue then
						-- It changed, so the device has a memory cell at this offset.
						deviceSize = deviceSize + 1
						entity:WriteCell(i, oldValue) -- Restore value
					else
						-- It didn't change, we've reached the end of memory.
						done = true
						break
					end
					
					if i > iterationStart and (i % readsPerIteration) == 0 then
						break
					end
				end

				iterationStart = nextIterationStart
				--print(iterationStart .. " - Device size: " .. deviceSize)
				
				if done or iterationStart >= iterationEnd then
					timer.Remove("WireMemViewerRequestDeviceSizeTimer")
					
					net.Start("WireMemViewerRequestDeviceSizeResponse")
					net.WriteEntity(entity)
					net.WriteInt(deviceSize, 32)
					net.Send(ply)
				end
			end)
		end
	end)
	
	net.Receive("WireMemViewerFillMemory", function(len, ply)
		local entity = net.ReadEntity()
		local address = net.ReadInt(32)
		local count = net.ReadInt(32)
		local value = net.ReadFloat()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		local canTool = true -- TODO    local canTool = hook.Run("CanTool", ply, util.GetPlayerTrace(ply), "wire_memviewer")
		if not canTool then return end
		print("FILL " .. count .. " ADDRESSES AT " .. address .. " OF " .. tostring(entity) .. " WITH " .. value)
		
		--for i = 0, count - 1 do
		--	entity:WriteCell(address + i, value)
		--end
		
		MultiTickIteration(0, count - 1, 8192, 0.1, function(i)
			if (i % 16768) == 0 then
				net.Start("WireMemViewerFillMemoryProgress")
				local progress = (i / count) * 100.0
				net.WriteFloat(progress)
				net.Send(ply)
			end
			entity:WriteCell(address + i, value)
			return true
		end)
	end)
end

local CurrentEntity = nil
local DeviceSize = 0
local Memory = {}
local MemoryStart = 0
local MemorySize = 0
local MemoryFillProgress = 0
MemoryViewerGUI = nil

if CLIENT then
	CreateClientConVar("wire_memviewer_displaymode", 0, true, false)
	CreateClientConVar("wire_memviewer_cellwidth", 64, true, false)
	CreateClientConVar("wire_memviewer_cellheight", 24, true, false)
	CreateClientConVar("wire_memviewer_columns", 10, true, false)
end

if CLIENT then
	net.Receive("WireMemViewerFillMemoryProgress", function(len, ply)
		local progress = net.ReadFloat()
		MemoryFillProgress = progress
	end)
	
	net.Receive("WireMemViewerRequestMemoryResponse", function(len, ply)
		local entity = net.ReadEntity()
		local start = net.ReadInt(32)
		local size = net.ReadInt(16)
		
		table.Empty(Memory)
		for i = 0, size - 1 do
			local address = start + i
			local value = net.ReadFloat()
			Memory[i] = value
		end
	end)
	
	net.Receive("WireMemViewerRequestDeviceSizeResponse", function(len, ply)
		local entity = net.ReadEntity()
		local deviceSize = net.ReadInt(32)
		DeviceSize = deviceSize
	end)
end

if CLIENT then
	function TOOL:GetMemory(memAddress)
		local entity = CurrentEntity
		if not entity then return end
		if not WireLib.HasPorts(entity) then return 0 end
		local offset = memAddress - MemoryStart
		local value = Memory[offset]
		return value
	end
	
	function TOOL:SetMemory(memAddress, value)
		if memAddress < 0 then return end
		if not CurrentEntity then return end
		Memory[memAddress - MemoryStart] = value
		net.Start("WireMemViewerSetAddress")
		net.WriteEntity(CurrentEntity)
		net.WriteInt(memAddress, 32)
		net.WriteFloat(value)
		net.SendToServer()
	end
	
	function TOOL:FillMemory(memAddress, count, value)
		if memAddress < 0 then return end
		if count < 0 then return end
		if not CurrentEntity then return end
		
		net.Start("WireMemViewerFillMemory")
		net.WriteEntity(CurrentEntity)
		net.WriteInt(memAddress, 32)
		net.WriteInt(count, 32)
		net.WriteFloat(value)
		net.SendToServer()
	end

	function TOOL:CreateViewerGUI()
		local tool = self
		if MemoryViewerGUI then
			MemoryViewerGUI:Remove()
		end
		
		local cellWidth = math.max(4, GetConVar("wire_memviewer_cellwidth"):GetInt()) --64
		local cellHeight = math.max(4, GetConVar("wire_memviewer_cellheight"):GetInt()) --24
		local columnCount = math.max(4, GetConVar("wire_memviewer_columns"):GetInt()) --10
		
		local window = vgui.Create("DFrame")
		MemoryViewerGUI = window
		window:SetTitle("Memory Viewer")
		window:SetWide(800)
		window:SetTall(600)
		window:SetPos(300,256)
		window:SetSizable(true)
		window:Hide()
		
		local lastHoverAddress = -1
		
		local statusBar = vgui.Create("DPanel", window)
		statusBar:Dock(BOTTOM)
		function statusBar:Paint(w, h)
			surface.SetDrawColor(60, 60, 60, 255)
			surface.DrawRect(0, 0, w, h)
			
			local statusText = "Entity: " .. tostring(CurrentEntity) .. " | "
			if DeviceSize > 0 then
				statusText = statusText .. "Memory size: " .. tostring(DeviceSize)
			else
				statusText = statusText .. "Memory size: Querying..."
			end
			
			if lastHoverAddress > -1 then
				statusText = statusText .. " | Address: " .. tostring(lastHoverAddress)
			else
				statusText = statusText .. " | Address: ???"
			end
			
			if MemoryFillProgress > 0 then
				statusText = statusText .. " | Filling memory: " .. MemoryFillProgress .. "%"
			end
			
			surface.SetFont("DermaDefault")
			local textW, textH = surface.GetTextSize(statusText)
			draw.DrawText(statusText, "DermaDefault", 8, (h / 2 - textH / 2) - 1, Color(255, 255, 255, 255), TEXT_ALIGN_LEFT)
		end
		
		function window:OnRemove()
			MemoryViewerGUI = nil
		end
		
		local scrollPanel = vgui.Create("DScrollPanel", window)
		scrollPanel:Dock(FILL)
		
		local menuBar = vgui.Create( "DMenuBar", window )
		menuBar:DockMargin(-3, -6, -3, 0)

		local editMenu = menuBar:AddMenu( "Edit" )
		local zeroMemoryOption = editMenu:AddOption("Zero all addresses...", function()
			Derma_Query("Are you sure you want to zero all addresses?", "Zero all addresses", "Yes", function()
				tool:FillMemory(0, DeviceSize, 0)
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
						tool:FillMemory(0, DeviceSize, value)
					end
				end
			end)
		end)
		fillMemoryOption:SetIcon("icon16/page_white_code_red.png")
		local menuView = menuBar:AddMenu( "View" )
		-- Because sub menus are broken
		local dmOpt1,dmOpt2,dmOpt3
		dmOpt1 = menuView:AddOption("Display mode: Floating point", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(0)
			dmOpt1:SetChecked(true)
			dmOpt2:SetChecked(false)
			dmOpt3:SetChecked(false)
		end)
		dmOpt2 = menuView:AddOption("Display mode: Alphanumeric", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(1)
			dmOpt1:SetChecked(false)
			dmOpt2:SetChecked(true)
			dmOpt3:SetChecked(false)
		end)
		dmOpt3 = menuView:AddOption("Display mode: Mixed", function()
			GetConVar("wire_memviewer_displaymode"):SetInt(2)
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
		local opt3
		opt3 = menuView:AddOption("Column width: 64", function()
			Derma_StringRequest("Set column width", "Enter the new column width", tostring(GetConVar("wire_memviewer_cellwidth"):GetInt()), function(text)
				local width = tonumber(text) or 64
				opt3:SetText("Column width: " .. width)
				GetConVar("wire_memviewer_cellwidth"):SetInt(width)
				cellWidth = width
			end)
		end)
		opt3:SetText("Column width: " .. GetConVar("wire_memviewer_cellwidth"):GetInt())
		opt3:SetIcon("icon16/arrow_right.png")
		local opt3
		opt4 = menuView:AddOption("Row height: 64", function()
			Derma_StringRequest("Set row height", "Enter the new row height", tostring(GetConVar("wire_memviewer_cellheight"):GetInt()), function(text)
				local height = tonumber(text) or 24
				opt4:SetText("Row height: " .. height)
				GetConVar("wire_memviewer_cellheight"):SetInt(height)
				cellHeight = height
			end)
		end)
		opt4:SetText("Row height: " .. GetConVar("wire_memviewer_cellheight"):GetInt())
		opt4:SetIcon("icon16/arrow_down.png")
		local opt5
		opt5 = menuView:AddOption("Columns: 64", function()
			Derma_StringRequest("Set columns", "Enter the new number of columns", tostring(GetConVar("wire_memviewer_columns"):GetInt()), function(text)
				local height = tonumber(text) or 24
				opt5:SetText("Columns: " .. height)
				GetConVar("wire_memviewer_columns"):SetInt(height)
				columnCount = height
			end)
		end)
		opt5:SetText("Columns: " .. GetConVar("wire_memviewer_columns"):GetInt())
		opt5:SetIcon("icon16/application_view_columns.png")
		
		local memoryPanel = vgui.Create("DPanel", window)
		memoryPanel:SetDrawBackground(true)
		memoryPanel:SetBackgroundColor(Color(0, 100, 100))
		memoryPanel:DockMargin(0, 6, 20, 0)
		memoryPanel:Dock(FILL)
		
		local scrollBar = vgui.Create("DVScrollBar", window)
		scrollBar:Dock(RIGHT)
		scrollBar:DockMargin(0,6,0,0)
		scrollBar:SetWide(20)
		scrollBar:SetScroll(0)
		local lastScrollValue = 0
		
		local currentEditAddress = -1
		local editBox = vgui.Create("DTextEntry", memoryPanel)
		editBox:Hide()
		editBox:SetSize(cellWidth, cellHeight)
		function editBox:OnEnter()
			if currentEditAddress < 0 then return end
			if not CurrentEntity then return end
			
			local text = editBox:GetValue()
			if string.len(text) > 0 then
				local value = tonumber(text)
				if value then
					tool:SetMemory(currentEditAddress, value)
				else
					tool:SetMemory(currentEditAddress, string.byte(text, 1))
				end
			end
			
			editBox:Hide()
			currentEditAddress = -1
		end
		
		function memoryPanel:OnMousePressed(keyCode)
			if keyCode == MOUSE_LEFT then
				editBox:Hide()
				editBox:KillFocus()
				
				local address = lastHoverAddress
				if address < 0 then return end
				if GetConVar("wire_memviewer_readonly"):GetBool() then
					tool:GetOwner():EmitSound("buttons/button11.wav")
					return
				end
				
				local value = tool:GetMemory(address)
				if not value then
					return
				end
				
				currentEditAddress = address
				LocalPlayer():ChatPrint(tostring(currentEditAddress))
				local x, y = self:CursorPos()
				x = math.floor(x / cellWidth) * cellWidth
				y = math.floor(y / cellHeight) * cellHeight
				editBox:SetPos(x, y)
				editBox:SetValue(tostring(value))
				editBox:SetText(tostring(value))
				editBox:SetSize(cellWidth, cellHeight)
				editBox:Show()
				editBox:SelectAll()
				editBox:RequestFocus()
			else
				if not editBox:IsVisible() then
					local address = lastHoverAddress
					if address < 0 then return end
					
					local menu = DermaMenu()
					local opt = menu:AddOption("Write string", function()
						Derma_StringRequest("Write string", "Enter the string to write, beginning at address " .. address, "Hello World", function(text)
							local textLen = string.len(text)
							for i = 0, textLen - 1 do
								local charValue = string.byte(text, i+1)
								tool:SetMemory(address+i,charValue)
							end
							tool:SetMemory(address+textLen,0) -- Zero terminate
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
									tool:FillMemory(address, count, value)
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
		
		function memoryPanel:OnMouseWheeled(scrollDelta)
			local scroll = scrollBar:GetScroll()
			local rowsPerScroll = 10
			scrollBar:SetScroll(scroll - (scrollDelta*columnCount*rowsPerScroll))
		end
		
		function memoryPanel:Paint(w, h)
			lastHoverAddress = -1
			local horizontalCellCount = 1 + columnCount --math.floor(w / cellWidth)
			local verticalCellCount = math.floor(h / cellHeight)
			
			local deviceSize = DeviceSize
			if (deviceSize < 1) then
				draw.DrawText("Querying memory, please wait...", "DermaDefault", 8, 8, Color(255, 255, 255, 255), TEXT_ALIGN_LEFT)
				return
			end
			
			local endAddress = deviceSize
			local startAddress = 0
			
			local aa = (horizontalCellCount-1) * (verticalCellCount-1)
			local bb = deviceSize + 64
			scrollBar:SetUp(aa, bb)
			
			local scroll = scrollBar:GetScroll()
			if scroll ~= lastScrollValue then
				lastScrollValue = scroll
				table.Empty(Memory)
			end
			
			startAddress = math.floor(endAddress * (scroll / deviceSize))
			startAddress = math.floor(startAddress / 10) * 10
			MemoryStart = startAddress
			MemorySize = math.min((horizontalCellCount-1) * (verticalCellCount-1), deviceSize - startAddress)
			
			local currentAddress = startAddress - 1
			
			for y = 0, verticalCellCount-1 do
				for x = 0, horizontalCellCount-1 do
					local r, g, b
					if (y % 2) == 0 then
						if (x % 2) == 0 then
							r = 255
							g = 255
							b = 255
						else
							r = 225
							g = 225
							b = 225
						end
					else
						if (x % 2) == 0 then
							r = 200
							g = 200
							b = 200
						else
							r = 175
							g = 175
							b = 175
						end
					end
					
					if x == 0 or y == 0 then
						r = r - 150
						g = g - 150
						b = b - 150
					else
						r = r - 50
						g = g - 50
						b = b - 50
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
					
					--[[if ((cursorPosX >= cellX) and
					   (cursorPosY >= cellY and cursorPosY <= cellY + cellHeight)) or
					   ((cursorPosX >= cellX and cursorPosX <= cellX + cellWidth) and
					    (cursorPosY >= cellY)) then
					   shouldHighlight = true
					end]]
					
					if (x == 0 and cursorPosY >= cellY and cursorPosY <= cellY + cellHeight) or
					   (y == 0 and cursorPosX >= cellX and cursorPosX <= cellX + cellWidth) then
						shouldHighlight = true
					end
					
					if isCursorOver then
						if x ~= 0 and y ~= 0 then
							b = b + 50
						else
							lastHoverAddress = -1
						end
					end
					
					if shouldHighlight then
						r = r + 70
						g = g + 100
						b = b + 70
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
						if #Memory > 0 then
							local mem = tool:GetMemory(currentAddress)
							if not mem or currentAddress >= DeviceSize then
								cellText = "??"
								cellTextColor = Color(150, 25, 25, 255)
								r = r + 1000
							else
								local displayMode = GetConVar("wire_memviewer_displaymode"):GetInt()
								if displayMode == 0 then
									cellText = tostring(mem)
									cellTextColor = Color(0, 0, 0, 255)
								elseif displayMode == 1 then
									local suc, char
									if mem == 9 then
										char = "\\t"
										suc = true
									else
										suc, char = pcall(string.char, mem)
									end
									
									if suc then
										cellText = "'" .. char .. "'"
									else
										cellText = "??"
									end
									
									cellTextColor = Color(0, 0, 0, 255)
								elseif displayMode == 2 then
									local suc, char
									if mem == 9 then
										char = "\\t"
										suc = true
									else
										suc, char = pcall(string.char, mem)
									end
									
									if suc then
										cellText = mem .. " '" .. char .. "'"
									else
										cellText = "??"
									end
									
									cellTextColor = Color(0, 0, 0, 255)
								end
							end
						else
							cellText = "###"
							cellTextColor = Color(150, 150, 25, 255)
							r = r + 50
							g = g + 50
						end
						
						if isCursorOver then
							lastHoverAddress = currentAddress
						end
					end
					
					surface.SetDrawColor(r, g, b, 255)
					surface.DrawRect(cellX, cellY, cellWidth, cellHeight)
					
					surface.SetFont("DermaDefault")
					local textW, textH = surface.GetTextSize(cellText)
					draw.DrawText(cellText, "DermaDefault", cellX + cellWidth / 2 - textW / 2, cellY + cellHeight / 2 - textH / 2, cellTextColor, TEXT_ALIGN_LEFT)
				end
			end
			
			--draw.DrawText(tostring(MemoryStart) .. " " .. tostring(MemorySize), "DermaDefault", 0, 0, Color(0,0,0,255), TEXT_ALIGN_LEFT)
		end
		
		/*local tileLayout = vgui.Create("DTileLayout", scrollPanel)
		tileLayout:SetBaseSize(32)
		tileLayout:SetDrawBackground(true)
		tileLayout:SetBackgroundColor(Color(0, 100, 100))
		tileLayout:DockMargin(0, 0, 0, 0)
		tileLayout:Dock(FILL)
		
		for i = 1, 8192 do
			tileLayout:Add(Label(" Label " .. i))
		end*/
	end
end

TOOL.ClientConVar[ "readonly" ] = "1"

function TOOL:LeftClick(trace)
	if SERVER then return end
	
	if not trace.Entity:IsValid() then return end
	if not WireLib.HasPorts(trace.Entity) then return end

	local ply = self:GetOwner()
	
	table.Empty(Memory)
	MemoryStart = 0
	MemorySize = 0
	DeviceSize = 0
	CurrentEntity = trace.Entity
	if not MemoryViewerGUI then
		self:CreateViewerGUI()
	end
	if MemoryViewerGUI then
		net.Start("WireMemViewerRequestDeviceSize")
		net.WriteEntity(CurrentEntity)
		net.SendToServer()
		MemoryViewerGUI:Show()
		MemoryViewerGUI:MakePopup()
	end
	
	return true
end

function TOOL:RightClick(trace)
end

if CLIENT then
	function TOOL:DrawHUD()
		if self:GetClientNumber("showports") == 0 then return end
		local ent = LocalPlayer():GetEyeTraceNoCursor().Entity
		if not ent:IsValid() then return end

		local inputs, outputs = WireLib.GetPorts(ent)

		if inputs and #inputs ~= 0 then
			surface.SetFont("Trebuchet24")
			local boxh, boxw = 0,0
			for _, port in ipairs(inputs) do
				local name, tp = unpack(port)
				local text = tp == "NORMAL" and name or string.format("%s [%s]", name, tp)
				port.text = text
				port.y = boxh
				local textw,texth = surface.GetTextSize(text)
				if textw > boxw then boxw = textw end
				boxh = boxh + texth
			end

			local boxx, boxy = ScrW()/2-boxw-32, ScrH()/2-boxh/2
			draw.RoundedBox(8,
				boxx-8, boxy-8,
				boxw+16, boxh+16,
				Color(109,146,129,192)
			)

			for _, port in ipairs(inputs) do
				surface.SetTextPos(boxx,boxy+port.y)
				if port[4] then
					surface.SetTextColor(Color(255,0,0,255))
				else
					surface.SetTextColor(Color(255,255,255,255))
				end
				surface.DrawText(port.text)
				port.text = nil
				port.y = nil
			end
		end

		if outputs and #outputs ~= 0 then
			surface.SetFont("Trebuchet24")
			local boxh, boxw = 0,0
			for _, port in ipairs(outputs) do
				local name, tp = unpack(port)
				local text = tp == "NORMAL" and name or string.format("%s [%s]", name, tp)
				port.text = text
				port.y = boxh
				local textw,texth = surface.GetTextSize(text)
				if textw > boxw then boxw = textw end
				boxh = boxh + texth
			end

			local boxx, boxy = ScrW()/2+32, ScrH()/2-boxh/2
			draw.RoundedBox(8,
				boxx-8, boxy-8,
				boxw+16, boxh+16,
				Color(109,146,129,192)
			)

			for _, port in ipairs(outputs) do
				surface.SetTextPos(boxx,boxy+port.y)
				surface.SetTextColor(Color(255,255,255,255))
				surface.DrawText(port.text)
				port.text = nil
				port.y = nil
			end
		end
	end
end

function TOOL:Reload(trace)
end


if SERVER then
	WireToolHelpers.SetupSingleplayerClickHacks(TOOL)
else
	function WireMemViewerThink()
		if MemorySize <= 0 then return end
		if not MemoryViewerGUI or not MemoryViewerGUI:IsValid() or not MemoryViewerGUI:IsVisible() then return end
		
		net.Start("WireMemViewerRequestMemory")
		net.WriteEntity(CurrentEntity)
		net.WriteInt(MemoryStart, 32)
		net.WriteInt(MemorySize, 16)
		net.SendToServer()
	end

	timer.Create("WireMemViewerThink", game.SinglePlayer() and 0.05 or 0.2, 0, WireMemViewerThink)
end

function TOOL.BuildCPanel(panel)
	panel:Help("#Tool.wire_memviewer.desc")
	panel:CheckBox("#Tool_wire_memviewer_readonly", "wire_memviewer_readonly")
end