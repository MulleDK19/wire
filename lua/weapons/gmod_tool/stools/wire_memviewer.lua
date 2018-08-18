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

if SERVER then
	util.AddNetworkString("WireMemViewerSetAddress")
	util.AddNetworkString("WireMemViewerRequestMemory")
	util.AddNetworkString("WireMemViewerRequestMemoryResponse")
	util.AddNetworkString("WireMemViewerRequestDeviceSize")
	util.AddNetworkString("WireMemViewerRequestDeviceSizeResponse")
	
	net.Receive("WireMemViewerSetAddress", function(len, ply)
		local entity = net.ReadEntity()
		local address = net.ReadInt(32)
		local value = net.ReadFloat()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		local canTool = true -- TODO    local canTool = hook.Run("CanTool", ply, util.GetPlayerTrace(ply), "wire_memviewer")
		if not canTool then return end
		print("SET ADDRESS " .. address .. " of " .. tostring(entity) .. " to " .. value)
		print(tostring(entity.WriteCell))
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
	
	net.Receive("WireMemViewerRequestDeviceSize", function(len, ply)
		local entity = net.ReadEntity()
		if not WireLib.HasPorts(entity) or not entity.WriteCell then return end
		
		-- Devices don't seem to contain a size, so we have to count the cells that can be changed.
		local deviceSize = 0
		for i = 0, 262144-1 do
			local oldValue = entity:ReadCell(i)
			entity:WriteCell(i, oldValue - 200) -- 200 is random.
			local value = entity:ReadCell(i)
			if value ~= oldValue then
				-- It changed, so the device has a memory cell at this offset.
				deviceSize = deviceSize + 1
				entity:WriteCell(i, oldValue)
			end
		end
		
		net.Start("WireMemViewerRequestDeviceSizeResponse")
		net.WriteEntity(entity)
		net.WriteInt(deviceSize, 32)
		net.Send(ply)
	end)
end

local CurrentEntity = nil
local DeviceSize = 0
local Memory = {}
local MemoryStart = 0
local MemorySize = 0
MemoryViewerGUI = nil

if CLIENT then
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

	function TOOL:CreateViewerGUI()
		local tool = self
		if MemoryViewerGUI then
			MemoryViewerGUI:Remove()
		end
		
		local window = vgui.Create("DFrame")
		MemoryViewerGUI = window
		window:SetTitle("Memory Viewer")
		window:SetWide(800)
		window:SetTall(600)
		window:SetPos(300,256)
		window:SetSizable(true)
		window:Hide()
		
		function window:OnRemove()
			MemoryViewerGUI = nil
			print("SET GUI TO NIL")
		end
		
		local scrollPanel = vgui.Create("DScrollPanel", window)
		scrollPanel:Dock(FILL)
		
		local memoryPanel = vgui.Create("DPanel", window)
		memoryPanel:SetDrawBackground(true)
		memoryPanel:SetBackgroundColor(Color(0, 100, 100))
		memoryPanel:DockMargin(0, 0, 20, 0)
		memoryPanel:Dock(FILL)
		
		local scrollBar = vgui.Create("DVScrollBar", window)
		scrollBar:Dock(RIGHT)
		scrollBar:SetWide(20)
		scrollBar:SetScroll(0)
		local lastScrollValue = 0
		
		local cellWidth = 64
		local cellHeight = 24
		
		local currentEditAddress = -1
		local editBox = vgui.Create("DTextEntry", memoryPanel)
		editBox:Hide()
		editBox:SetSize(cellWidth, cellHeight)
		function editBox:OnEnter()
			if currentEditAddress < 0 then return end
			if not CurrentEntity then return end
			
			local text = editBox:GetValue()
			local value = tonumber(text)
			if value then
				tool:SetMemory(currentEditAddress, value)
			end
			
			editBox:Hide()
			currentEditAddress = -1
		end
		
		local lastHoverAddress = -1
		function memoryPanel:OnMousePressed(keyCode)
			if keyCode ~= MOUSE_LEFT then return end
			local address = lastHoverAddress
			if address < 0 then return end
			
			currentEditAddress = address
			local x, y = self:CursorPos()
			x = math.floor(x / cellWidth) * cellWidth
			y = math.floor(y / cellHeight) * cellHeight
			editBox:SetPos(x, y)
			editBox:SetValue(tostring(tool:GetMemory(address)))
			editBox:Show()
			editBox:SelectAll()
			editBox:RequestFocus()
		end
		
		function memoryPanel:Paint(w, h)
			local horizontalCellCount = math.floor(w / cellWidth)
			local verticalCellCount = math.floor(h / cellHeight)
			
			local deviceSize = DeviceSize
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
					if (cursorPosX >= cellX and cursorPosX <= cellX + cellWidth) and
					   (cursorPosY >= cellY and cursorPosY <= cellY + cellHeight) then
					   isCursorOver = true
					end
					
					if isCursorOver then
						if x ~= 0 and y ~= 0 then
							b = b + 50
						else
							lastHoverAddress = -1
						end
					end
					
					local cellText
					local cellTextColor
					if x == 0 and y == 0 then
						cellText = "---"
						cellTextColor = Color(0, 0, 0, 255)
					elseif x == 0 then
						local visualAddress = startAddress + ((horizontalCellCount-1) * (y - 1))
						cellText = tostring(visualAddress)
						cellTextColor = Color(255, 255, 255, 255)
					elseif y == 0 then
						local visualAddress = (-1 + y + x)
						cellText = tostring(visualAddress)
						cellTextColor = Color(255, 255, 255, 255)
					else
						currentAddress = currentAddress + 1
						if #Memory > 0 then
							local mem = tool:GetMemory(currentAddress)
							if mem then
								cellText = tostring(mem)
								cellTextColor = Color(0, 0, 0, 255)
							else
								cellText = "??"
								cellTextColor = Color(150, 25, 25, 255)
								r = r + 100
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
		print("1 " .. tostring(MemoryViewerGUI))
		if not MemoryViewerGUI or not MemoryViewerGUI:IsValid() or not MemoryViewerGUI:IsVisible() then return end
		print("2")
		
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