--------------------------------------------------------------------------------
-- ZCPU utility & support code
--------------------------------------------------------------------------------
local INVALID_BREAKPOINT_IP = 2e7

CPULib = CPULib or {}
if CLIENT then
  -- Sourcecode available as compiled binary
  CPULib.Source = ""
  -- Compiled binary
  CPULib.Buffer = {}

  -- Sourcecode currently being compiled
  CPULib.CurrentSource = ""
  -- Buffer currently being written
  CPULib.CurrentBuffer = {}

  -- State variables
  CPULib.Compiling = false
  CPULib.Uploading = false
  CPULib.ServerUploading = false

  -- Debugger
  CPULib.DebuggerAttached = false
  CPULib.Debugger = {}
  CPULib.Debugger.Variables = {}
  CPULib.Debugger.Stack = {}
  CPULib.Debugger.SourceTab = nil

  -- Reset on recompile
  CPULib.Debugger.MemoryVariableByIndex = {}
  CPULib.Debugger.MemoryVariableByName = {}
  CPULib.Debugger.Labels = {}
  CPULib.Debugger.PositionByPointer = {}
  CPULib.Debugger.PointersByLine = {}

  CPULib.Debugger.Breakpoint = {}

  -- Convars to control CPULib
  local wire_cpu_upload_speed = CreateClientConVar("wire_cpu_upload_speed",1000,false,false)
  local wire_cpu_compile_speed = CreateClientConVar("wire_cpu_compile_speed",256,false,false)
  local wire_cpu_show_all_registers = CreateClientConVar("wire_cpu_show_all_registers",0,false,false)

  ------------------------------------------------------------------------------
  -- Request compiling specific sourcecode
  function CPULib.Compile(source,fileName,successCallback,errorCallback,targetPlatform)
    -- Stop any compile/upload process that is running right now
    timer.Remove("cpulib_compile")
    timer.Remove("cpulib_upload")
    CPULib.Uploading = false

    -- See if compiled source is available
    --if CPULib.Source == source then
    --  successCallback()
    --  return
    --end

    -- Remember the sourcecode being compiled
    CPULib.CurrentSource = source
    CPULib.CurrentBuffer = {}

    -- Clear debugging info
    CPULib.Debugger.MemoryVariableByIndex = {}
    CPULib.Debugger.MemoryVariableByName = {}
    CPULib.Debugger.Labels = {}
    CPULib.Debugger.PositionByPointer = {}
    CPULib.Debugger.PointersByLine = {}
    CPULib.CPUName = nil

    -- Start compiling the sourcecode
    HCOMP:StartCompile(source,fileName or "source",CPULib.OnWriteByte,nil)
    HCOMP.Settings.CurrentPlatform = targetPlatform or "CPU"
    print("=== HL-ZASM High Level Assembly Compiler Output ==")

    -- Initialize callbacks
    CPULib.SuccessCallback = successCallback
    CPULib.ErrorCallback = errorCallback

    -- Run the timer
    timer.Create("cpulib_compile",1/60,0,CPULib.OnCompileTimer)
    CPULib.Compiling = true
  end

  ------------------------------------------------------------------------------
  -- Make sure the file is opened in the tab
  function CPULib.SelectTab(editor,fileName)
    if not editor then return end
    local editorType = string.lower(editor.EditorType)
    local fullFileName = editorType.."chip/"..fileName

    if string.sub(fileName,1,7) == editorType.."chip" then
      fullFileName = fileName
    end

    local sourceTab
    for tab=1,editor:GetNumTabs() do
      if editor:GetEditor(tab).chosenfile == fullFileName then
        sourceTab = tab
      end
    end

    if not sourceTab then
      editor:LoadFile(fullFileName,true)
      sourceTab = editor:GetActiveTabIndex()
    else
      editor:SetActiveTab(sourceTab)
    end

    return editor:GetEditor(sourceTab),sourceTab
  end

  ------------------------------------------------------------------------------
  -- Request validating the code
  function CPULib.Validate(editor,source,fileName)
    CPULib.Compile(source,fileName,
      function()
        editor.C.Val:SetBGColor(50, 128, 20, 180)
        editor.C.Val:SetFGColor(255, 255, 255, 128)
        editor.C.Val:SetText("   Success, "..(HCOMP.WritePointer or "?").." bytes compiled.")
      end,
      function(error,errorPos)
        editor.C.Val:SetBGColor(128, 20, 50, 180)
        editor.C.Val:SetFGColor(255, 255, 255, 128)
        editor.C.Val:SetText("   "..(error or "unknown error"))

        if not errorPos then return end

        local textEditor = CPULib.SelectTab(editor,errorPos.File)
        if not textEditor then return end
        textEditor:SetCaret({errorPos.Line,errorPos.Col})
      end,editor.EditorType)
  end

  ------------------------------------------------------------------------------
  -- Compiler callback
  function CPULib.OnWriteByte(caller,address,byte)
    CPULib.CurrentBuffer[address] = byte
  end

  ------------------------------------------------------------------------------
  -- Compiler timer
  function CPULib.OnCompileTimer()
    local compile_speed = wire_cpu_compile_speed:GetFloat()

    for _ = 1, compile_speed do
      local status,result = pcall(HCOMP.Compile,HCOMP)
      if not status then
        print("==================================================")
        if CPULib.ErrorCallback then CPULib.ErrorCallback(HCOMP.ErrorMessage or ("Internal error: "..result),HCOMP.ErrorPosition) end
        timer.Remove("cpulib_compile")
        CPULib.Compiling = false

        return
      elseif not result then
        print("==================================================")
        CPULib.Source = CPULib.CurrentSource
        CPULib.Buffer = CPULib.CurrentBuffer

        if CPULib.SuccessCallback then
          CPULib.Debugger.Labels = HCOMP.DebugInfo.Labels
          CPULib.Debugger.PositionByPointer = HCOMP.DebugInfo.PositionByPointer
          CPULib.Debugger.PointersByLine = HCOMP.DebugInfo.PointersByLine
		  
		  -- Calculate the size of local variables.
		  if CPULib.Debugger and CPULib.Debugger.Labels and CPULib.Debugger.Labels["locals"] then
			  for functionName, functionTable in pairs(CPULib.Debugger.Labels["locals"]) do
				local labelOrder = {}
				for label, labelTable in pairs(functionTable) do
					table.insert(labelOrder, label)
				end
				table.sort(labelOrder, function(a, b)
					return (functionTable[a].StackOffset or 0) > (functionTable[b].StackOffset or 0)
				end)
				local previousStackOffset = 0
				for i, labelName in pairs(labelOrder) do
					local stackOffset = functionTable[labelName].StackOffset or 0
					local size
					if stackOffset >= 0 then
						size = 1 -- Assume parameters are always size 1.
					else
						size = previousStackOffset - stackOffset
						previousStackOffset = stackOffset
					end
					
					functionTable[labelName].Size = size
				end
			  end
		  end
			  
          CPULib.SuccessCallback()
        end
        timer.Remove("cpulib_compile")
        CPULib.Compiling = false

        return
      end
    end
  end


  ------------------------------------------------------------------------------
  -- Uploader timer
  function CPULib.OnUploadTimer()
    if not CPULib.RemainingData then return end

    local upload_speed = wire_cpu_upload_speed:GetFloat() -- Number of index/value pairs to send (11 bytes each)
    if game.SinglePlayer() then upload_speed = 5000 end

    local iters = math.min(upload_speed, CPULib.RemainingUploadData)
    net.Start("wire_cpulib_buffer")
    net.WriteUInt(iters, 16)
    for _ = 1, iters do
      local index,value = next(CPULib.RemainingData)
      CPULib.RemainingUploadData = CPULib.RemainingUploadData - 1
      net.WriteUInt(index, 24)
      net.WriteDouble(value or 0) -- 64bits, in case theres any float literals. Int21 is sufficient for all function calls/memory addresses
      CPULib.RemainingData[index] = nil
    end
    if CPULib.RemainingUploadData <= 0 then
      timer.Remove("cpulib_upload")
      net.WriteBit(true) -- End
      CPULib.Uploading = false
    else
      net.WriteBit(false) -- Keep going
    end
    net.SendToServer()
  end

  ------------------------------------------------------------------------------
  -- Start upload
  function CPULib.Upload(customBuffer)
    -- Stop any upload in the progress
    timer.Remove("cpulib_upload")

    -- Send the buffer over to server
    net.Start("wire_cpulib_bufferstart") net.WriteString(CPULib.CPUName or "") net.SendToServer()

    CPULib.TotalUploadData = 0
    CPULib.RemainingData = {}
    if customBuffer then
      for k,v in pairs(customBuffer) do
        CPULib.RemainingData[k] = v
        CPULib.TotalUploadData = CPULib.TotalUploadData + 1
      end
    else
      for k,v in pairs(CPULib.Buffer) do
        CPULib.RemainingData[k] = v
        CPULib.TotalUploadData = CPULib.TotalUploadData + 1
      end
    end

    CPULib.RemainingUploadData = CPULib.TotalUploadData
    timer.Create("cpulib_upload",0.5,0,CPULib.OnUploadTimer)
    CPULib.Uploading = true
  end

  ------------------------------------------------------------------------------
  -- Get debug text for specific variable/function name
function CPULib.DrawDebugPopupBox(panel, var, pos)
	local csvar = string.upper(var)
	local popupX, popupY = pos[1], pos[2]
	local borderSize = 10
	
	local function getTextSize(font, text)
		surface.SetFont(font)
		local w, h = surface.GetTextSize(text)
		return w, h
	end
	
	local popupHeader = nil
	local popupFields = {}
	local function setHeader(text)
		popupHeader = text
	end
	
	local function addField(name, value, nameColor, valueColor)
		local field = {}
		field.Name = name
		field.Value = value
		field.NameColor = nameColor or Color(255, 200, 25, 255)
		field.ValueColor = valueColor or Color(255, 255, 255, 255)
		table.insert(popupFields, field)
	end
	
	local function drawPopup()
		local headerFont = "GModNotify"
		local fieldFont = "ChatFont"
		borderColor = textColor or Color(255, 255, 255, 255)
		surface.SetFont(headerFont)
		local _, headerHeight = surface.GetTextSize(popupHeader)
		
		local fieldsWidth = 0
		local fieldsHeight = 0
		
		local x, y = 0, 0
		for _, field in pairs(popupFields) do
			local name = field.Name
			local value = field.Value
			field.NameOffsetX = x
			field.NameOffsetY = y
			field.ValueOffsetX = x + 160
			field.ValueOffsetY = y
			surface.SetFont(fieldFont)
			local valueWidth, valueHeight = surface.GetTextSize(value)
			if x + 160 + valueWidth > fieldsWidth then
				fieldsWidth = x + 160 + valueWidth
			end
			y = y + valueHeight
			fieldsHeight = fieldsHeight + valueHeight
		end
		
		local borderWidth = borderSize+fieldsWidth+12
		local borderHeight = borderSize+fieldsHeight + 25
		popupY = popupY - borderHeight - 16
		if popupY < 0 then
			popupY = 0
		end
		--popupX = panel:GetWide() - borderWidth
		--popupY = panel:GetTall() - borderHeight
		draw.RoundedBox(borderSize, popupX, popupY, borderWidth, borderHeight, Color(0,0,25,245))
		draw.DrawText(popupHeader, headerFont, popupX + 4 + borderSize/2 + x, popupY + borderSize/2, Color(25, 200, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		for _, field in pairs(popupFields) do
			draw.DrawText(field.Name, fieldFont, popupX + 12+field.NameOffsetX, 25+popupY + field.NameOffsetY, field.NameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
			draw.DrawText(field.Value, fieldFont, popupX + 12+field.ValueOffsetX, 25+popupY + field.ValueOffsetY, field.ValueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
	end
	
	local nameFieldColor = Color(50, 255, 100, 255)
	local valueFieldColor = Color(150, 255, 150, 255)
	
	if CPULib.Debugger.Labels["locals"] then
		-- Find a local variable with this name.
		local localsTable = CPULib.Debugger.Labels["locals"]
		local xeip = (CPULib.Debugger.Variables.IP or 0) + (CPULib.Debugger.Variables.CS or 0)
		local finalLocalTable = nil
		local highestPointer = -999999
		local functionName = nil
		for labelName, labelTable in pairs(CPULib.Debugger.Labels) do
			if labelName == "locals" then continue end
			
			local ptr = labelTable.Pointer or -999999
			if xeip >= ptr and ptr > highestPointer then
				highestPointer = ptr
				functionName = labelName
			end
		end
		
		if functionName then
			local functionLocalsTable = localsTable[functionName]
			if functionLocalsTable then
				local localTable = functionLocalsTable[csvar]
				if localTable then
					functionLabel = labelName
					smallestPointer = labelPointer
					finalLocalTable = localTable
					finalLocalTableFunctionName = labelName
				end
			end
		end

		if finalLocalTable then
			if finalLocalTable["Type"] == "Stack" then
				if finalLocalTable["StackOffset"] then
					local stackOffset = finalLocalTable.StackOffset
					local size = finalLocalTable.Size or 1
					local ebpEsp = (CPULib.Debugger.Variables.EBP or 0) - (CPULib.Debugger.Variables.ESP or 0)
					
					if stackOffset >= 0 then
						setHeader("PARAMETER VARIABLE")
					else
						setHeader("LOCAL VARIABLE")
					end
					addField("Name", finalLocalTable.Name, nil, nameFieldColor)

					local stackAddress = CPULib.Debugger.Variables.EBP + CPULib.Debugger.Variables.SS + stackOffset

					local finalString
					if stackOffset >= 0 then
						finalString = "PARAMETER VARIABLE\n"
					else
						finalString = "LOCAL VARIABLE\n"
					end
					
					if stackOffset >= 0 then
						addField("Stack offset", "EBP+"..stackOffset)
					else
						addField("Stack offset", "EBP-"..math.abs(stackOffset))
					end
					if size ~= 1 then
						addField("Size", tostring(size))
					end
					
					addField("Address", tostring(stackAddress))
					
					local isPossiblyString = false
					if size == 1 then
						local stackValue = CPULib.Debugger.Stack[math.abs(ebpEsp+stackOffset)] or 0
						local characterValue = nil
						if stackValue >= 32 and stackValue <= 126 then
							characterValue = string.char(stackValue)
							isPossiblyString = true
						end
						addField("Float value", tostring(stackValue), nil, valueFieldColor)
						if characterValue and size == 1 then
							addField("Character value", "'" .. characterValue .. "'")
						end
					else
						local floatValuesString = nil
						local characterValuesString = nil
						for i = 0, size-1 do
							local stackValue = CPULib.Debugger.Stack[math.abs(ebpEsp+stackOffset+i)] or 0
							local characterValue = nil
							if stackValue >= 32 and stackValue <= 126 then
								characterValue = string.char(stackValue)
								isPossiblyString = true
							else
								characterValue = "0"
							end
							if not floatValuesString then
								floatValuesString = tostring(stackValue)
							else
								floatValuesString = floatValuesString .. ", " .. tostring(stackValue)
							end
							if isPossiblyString then
								if not characterValuesString then
									characterValuesString = "'" .. characterValue .. "'"
								else
									characterValuesString = characterValuesString .. ", '" .. characterValue .. "'"
								end
							end
						end
						
						if floatValuesString then
							addField("Float values", floatValuesString, nil, valueFieldColor)
						end
						if characterValuesString then
							addField("Character values", characterValuesString)
						end
						
						if isPossiblyString then
							stringValue = ""
							for i = 0, size - 1 do
								local stackValue = CPULib.Debugger.Stack[math.abs(ebpEsp+stackOffset+i)] or 0
								if stackValue == 0 then break end
								local character
								if stackValue >= 32 and stackValue <= 126 then
									character = string.char(stackValue)
								else
									character = "?"
								end
								
								stringValue = stringValue .. tostring(character)
							end
							addField("String value", "\"" .. stringValue .. "\"")
						end
					end
					
					drawPopup()
					return true
				end
			elseif finalLocalTable["Type"] == "Register" then
				local register = finalLocalTable.Register or 0
				local registerName = ""
				if register == 1 then registerName = "EAX"
				elseif register == 2 then registerName = "EBX"
				elseif register == 3 then registerName = "ECX"
				elseif register == 4 then registerName = "EDX"
				elseif register == 5 then registerName = "ESI"
				elseif register == 6 then registerName = "EDI"
				elseif register == 7 then registerName = "IP" end
				local registerValue = CPULib.Debugger.Variables[registerName] or 0
				
				setHeader("REGISTER VARIABLE")
				addField("Name", finalLocalTable.Name, nil, nameFieldColor)
				addField("Register", registerName)
				
				local characterValue = nil
				if registerValue >= 32 and registerValue <= 126 then
					characterValue = string.char(registerValue)
				end
				addField("Float value", tostring(registerValue), nil, valueFieldColor)
				if characterValue then
					addField("Character value", "'" .. characterValue .. "'")
				end
				drawPopup()
				
				return true
			end
		end
	end
	
	if CPULib.Debugger.Variables[csvar] then
		if not CPULib.Debugger.MemoryVariableByName[csvar] then
			setHeader("REGISTER")
			addField("Name", csvar, nil, nameFieldColor)
			addField("Value", CPULib.Debugger.Variables[csvar], nil, valueFieldColor)
		else
			setHeader("VARIABLE")
			addField("Name", var, nil, nameFieldColor)
			local ptr = CPULib.Debugger.MemoryVariableByName[csvar]
			addField("Offset", ptr)
			addField("Value", CPULib.Debugger.Variables[csvar], nil, valueFieldColor)
		end
		drawPopup()
		return true
    end
	
	if CPULib.Debugger.Labels[csvar] then
		setHeader("LABEL")
		addField("Name", var, nil, nameFieldColor)
		if CPULib.Debugger.Labels[csvar].Offset then
			if not CPULib.Debugger.MemoryVariableByName[csvar] then
				CPULib.Debugger.MemoryVariableByName[csvar] = CPULib.Debugger.Labels[csvar].Offset
				table.insert(CPULib.Debugger.MemoryVariableByIndex,csvar)
				RunConsoleCommand("wire_cpulib_debugvar",#CPULib.Debugger.MemoryVariableByIndex,CPULib.Debugger.Labels[csvar].Offset)
			end
			
			
			addField("Value", "...", nil, valueFieldColor)
		elseif CPULib.Debugger.Labels[csvar].Pointer then
			local ptr = CPULib.Debugger.Labels[csvar].Pointer
			addField("Offset", tostring(ptr))
			addField("Value", "...", nil, valueFieldColor)
		else
			addField("Value", "???", nil, valueFieldColor)
		end
		
		drawPopup()
		return true
	end
	
	-- Lastly, look up instruction info
	local opcode = CPULib.MnemonicToInstructionTable[csvar]
	if opcode then
		local instruction = CPULib.InstructionTable[opcode]
		if instruction then
			local set = instruction.Set
			opcode = instruction.Opcode or 0
			local mnemonic = instruction.Mnemonic or "ERROR"
			local reference = instruction.Reference or "NO DESCRIPTION"
			local op1 = instruction.Operand1
			local op2 = instruction.Operand2
			if op1 == "" then op1 = nil end
			if op2 == "" then op2 = nil end
			
			local header = mnemonic
			if op1 then
				header = header .. " " .. op1
			end
			if op2 then
				header = header .. ", " .. op2
			end
			
			setHeader(header)
			addField("Set", set)
			addField("Opcode", opcode, nil, valueFieldColor)
			addField("Mnemonic", mnemonic, nil, nameFieldColor)
			addField("Description", reference, nil, valueFieldColor)
			drawPopup()
			return true
		end
	end
	
	return false
end
  
  function CPULib.GetDebugPopupText(var)
    if not var then return "" end
    local csvar = string.upper(var)

    if CPULib.Debugger.Variables[csvar] then
	  if not CPULib.Debugger.MemoryVariableByName[csvar] then
        return var.." = "..CPULib.Debugger.Variables[csvar]
	  else
		local ptr = CPULib.Debugger.MemoryVariableByName[csvar]
	    return ptr .. ": "..var.." = "..CPULib.Debugger.Variables[csvar]
	  end
    else
      if CPULib.Debugger.Labels[csvar] then
        if CPULib.Debugger.Labels[csvar].Offset then
          if not CPULib.Debugger.MemoryVariableByName[csvar] then
            CPULib.Debugger.MemoryVariableByName[csvar] = CPULib.Debugger.Labels[csvar].Offset
            table.insert(CPULib.Debugger.MemoryVariableByIndex,csvar)
            RunConsoleCommand("wire_cpulib_debugvar",#CPULib.Debugger.MemoryVariableByIndex,CPULib.Debugger.Labels[csvar].Offset)
          end
          return var.." = ..."
        elseif CPULib.Debugger.Labels[csvar].Pointer then
		  local ptr = CPULib.Debugger.Labels[csvar].Pointer
          return ptr..": "..var.." = ?"
        else
          return var.." = cannot resolve"
        end
	  elseif CPULib.Debugger.Labels["locals"] then
		  -- Find a local variable with this name.
		  local localsTable = CPULib.Debugger.Labels["locals"]
		  local xeip = (CPULib.Debugger.Variables.IP or 0) + (CPULib.Debugger.Variables.CS or 0)
		  local finalLocalTable = nil
	      for labelName, labelTable in pairs(CPULib.Debugger.Labels) do
			if labelName == "locals" then continue end
			local labelPointer = labelTable.Pointer or -10000
			if xeip >= labelPointer then
				local functionLocalsTable = localsTable[labelName]
				if functionLocalsTable then
					local localTable = functionLocalsTable[csvar]
					if localTable then
						finalLocalTable = localTable
						finalLocalTableFunctionName = labelName
					end
				end
			end
		  end
		  
		  if finalLocalTable then
			if finalLocalTable["Type"] == "Stack" then
				if finalLocalTable["StackOffset"] then
					local stackOffset = finalLocalTable.StackOffset
					local size = finalLocalTable.Size
					local ebpEsp = CPULib.Debugger.Variables.EBP - CPULib.Debugger.Variables.ESP

					local stackAddress = CPULib.Debugger.Variables.EBP + CPULib.Debugger.Variables.SS + stackOffset

					local finalString = "STACK VARIABLE\n"
					if stackOffset >= 0 then
						finalString = finalString .. "[ebp+"..stackOffset.."] / "..stackAddress..": "..finalLocalTable.Name.." = "
					else
						finalString = finalString .. "[ebp-"..math.abs(stackOffset).."] / "..stackAddress..": "..finalLocalTable.Name.." = "
					end
					
					local containsCharacters = false
					for i = 0,size-1 do
						local stackValue = CPULib.Debugger.Stack[math.abs(ebpEsp+stackOffset+i)] or 0
						local finalStackValue
						if stackValue >= 32 and stackValue <= 126 then
							finalStackValue = tostring(stackValue) .. " '" .. string.char(stackValue) .. "'"
							containsCharacters = true
						else
							finalStackValue = tostring(stackValue)
						end
						
						if i < size-1 then
							finalString = finalString .. finalStackValue .. ", "
						else
							finalString = finalString .. finalStackValue
						end
					end
					
					if containsCharacters then
						finalString = finalString .. " \""
						for i = 0,size-1 do
							local stackValue = CPULib.Debugger.Stack[math.abs(ebpEsp+stackOffset+i)]
							if stackValue == 0 then
								break
							else
								if stackValue >= 32 and stackValue <= 126 then
									finalString = finalString .. string.char(stackValue)
								else
									finalString = finalString .. "?"
								end
							end
						end
						
						finalString = finalString .. "\""
					end
					
					return finalString
				end
			elseif finalLocalTable["Type"] == "Register" then
				local register = finalLocalTable.Register or 0
				local registerName = ""
				if register == 1 then registerName = "EAX"
				elseif register == 2 then registerName = "EBX"
				elseif register == 3 then registerName = "ECX"
				elseif register == 4 then registerName = "EDX"
				elseif register == 5 then registerName = "ESI"
				elseif register == 6 then registerName = "EDI"
				elseif register == 7 then registerName = "IP" end
				local registerValue = CPULib.Debugger.Variables[registerName] or 0
				return "REGISTER VARIABLE\n" .. registerName .. ": " .. finalLocalTable.Name .. " = " .. registerValue
			end
		  end
	  end
		-- Lastly, look up instruction info
		local opcode = CPULib.MnemonicToInstructionTable[csvar]
		if opcode then
			local instruction = CPULib.InstructionTable[opcode]
			if instruction then
				local set = instruction.Set
				opcode = instruction.Opcode or 0
				local mnemonic = instruction.Mnemonic or "ERROR"
				local reference = instruction.Reference or "NO DESCRIPTION"
				local op1 = instruction.Operand1
				local op2 = instruction.Operand2
				if op1 == "" then op1 = nil end
				if op2 == "" then op2 = nil end
				local finalDescription = set .. ": " .. opcode .. " " .. mnemonic
				if op1 then
					finalDescription = finalDescription .. " " .. op1
				end
				if op2 then
					finalDescription = finalDescription .. ", " .. op2
				end
				finalDescription = finalDescription .. "     // " .. reference
				return finalDescription
			end
		end
    end
  end

  ------------------------------------------------------------------------------
  -- Get debug text for specific variable/function name
  CPULib.InterruptText = nil
  function CPULib.GetDebugWindowText()
	local timerValue = CPULib.Debugger.Variables.TIMER or 0
	timerValue = math.Round(timerValue * 100000000) / 100000000
    local result = {
      "EAX = "..(CPULib.Debugger.Variables.EAX or "#####"),
      "EBX = "..(CPULib.Debugger.Variables.EBX or "#####"),
      "ECX = "..(CPULib.Debugger.Variables.ECX or "#####"),
      "EDX = "..(CPULib.Debugger.Variables.EDX or "#####"),
      "ESI = "..(CPULib.Debugger.Variables.ESI or "#####"),
      "EDI = "..(CPULib.Debugger.Variables.EDI or "#####"),
      "EBP = "..(CPULib.Debugger.Variables.EBP or "#####"),
      "ESP = "..(CPULib.Debugger.Variables.ESP or "#####"),
      "",
	  "CS = "..(CPULib.Debugger.Variables.CS or "#####"),
	  "SS = "..(CPULib.Debugger.Variables.SS or "#####"),
	  "DS = "..(CPULib.Debugger.Variables.DS or "#####"),
	  "ES = "..(CPULib.Debugger.Variables.ES or "#####"),
	  "GS = "..(CPULib.Debugger.Variables.GS or "#####"),
	  "FS = "..(CPULib.Debugger.Variables.FS or "#####"),
	  "KS = "..(CPULib.Debugger.Variables.KS or "#####"),
	  "LS = "..(CPULib.Debugger.Variables.LS or "#####"),
    }

    table.insert(result,"")
    local maxReg = 7
    if wire_cpu_show_all_registers:GetFloat() == 1 then maxReg = 31 end

    for reg=0,maxReg do
      table.insert(result,"R"..reg.." = "..(CPULib.Debugger.Variables["R"..reg] or "#####"))
    end


    table.insert(result,"")
    if CPULib.Debugger.Variables.IP == INVALID_BREAKPOINT_IP then
      table.insert(result,"IP = #####")
      table.insert(result,"XEIP = #####")
    else
      table.insert(result,"IP = "..(CPULib.Debugger.Variables.IP or "#####"))
	  local ip = CPULib.Debugger.Variables.IP
	  local cs = CPULib.Debugger.Variables.CS
	  if ip and cs then
		table.insert(result,"XEIP = "..(ip+cs))
	  else
	    table.insert(result,"XEIP = "..("#####"))
	  end
    end
	
	if wire_cpu_show_all_registers:GetFloat() == 1 then
		table.insert(result,"")
		
		table.insert(result,"TIMER = "..(timerValue or "#####"))
		table.insert(result,"TMR = "..(CPULib.Debugger.Variables.TMR or "#####"))
		table.insert(result,"CMPR = "..(CPULib.Debugger.Variables.CMPR or "#####"))
		
		table.insert(result,"")
		local i = 0
		for stackOffset, stack in pairs(CPULib.Debugger.Stack) do
			local stackString
			if stack >= 32 and stack <= 126 then
				stackString = tostring(stack) .. " '" .. string.char(stack) .. "'"
			else
				stackString = tostring(stack)
			end
			if CPULib.Debugger.Variables.SS == 0 then
				table.insert(result, "[ESP+"..stackOffset.."] = " .. stackString)
			else
				table.insert(result, "[ESP+SS+"..stackOffset.."] = " .. stackString)
			end
			i = i + 1
			if i >= 30 then break end
		end
	end

    if CPULib.InterruptText then
      table.insert(result,"")
      table.insert(result,CPULib.InterruptText)
    end

    return result
  end

  ------------------------------------------------------------------------------
  -- Invalidate debugger data
  function CPULib.InvalidateDebugger()
    CPULib.InterruptText = nil
    CPULib.Debugger.MemoryVariableByIndex = {}
    CPULib.Debugger.MemoryVariableByName = {}
    CPULib.Debugger.Breakpoint = {}
    CPULib.Debugger.Variables = {}
    CPULib.Debugger.Stack = {}
    CPULib.Debugger.FirstFile = nil
    CPULib.DebugUpdateHighlights()
	
	-- Remove current statement
	if ZCPU_Editor then
	  for tab=1,ZCPU_Editor:GetNumTabs() do
  	    ZCPU_Editor:GetEditor(tab):ClearHighlightedLines()
	  end
	end
  end

  net.Receive("CPULib.InvalidateDebugger", function(netlen)
    local state = net.ReadUInt(2) -- 0: No change just invalidate, 1: detach, 2: attach
    if state == 1 then
      CPULib.DebuggerAttached = false
      GAMEMODE:AddNotify("CPU debugger detached!",NOTIFY_GENERIC,7)
    elseif state == 2 then
      CPULib.DebuggerAttached = true
      GAMEMODE:AddNotify("CPU debugger has been attached!",NOTIFY_GENERIC,7)
    end
    CPULib.InvalidateDebugger()
  end)

  -- Get breakpoint at line
  function CPULib.GetDebugBreakpoint(fileName,caretPos)
    if not fileName or not caretPos then return nil end
    return CPULib.Debugger.Breakpoint[caretPos[1]..":"..fileName]
  end

  -- Set breakpoint at line
  -- FIXME: bug: can only set breakpoints in one file
  function CPULib.SetDebugBreakpoint(fileName,caretPos,condition)
    if not fileName or not caretPos then return nil end
    if not condition then
      CPULib.Debugger.Breakpoint[caretPos[1]..":"..fileName] = nil
      if CPULib.Debugger.PointersByLine[caretPos[1]..":"..fileName] then
        RunConsoleCommand("wire_cpulib_debugbreakpoint",CPULib.Debugger.PointersByLine[caretPos[1]..":"..fileName][1],0)
      end
    else
      if CPULib.Debugger.PointersByLine[caretPos[1]..":"..fileName] then
        CPULib.Debugger.Breakpoint[caretPos[1]..":"..fileName] = condition
        RunConsoleCommand("wire_cpulib_debugbreakpoint",CPULib.Debugger.PointersByLine[caretPos[1]..":"..fileName][1],condition)
      end
    end

    CPULib.DebugUpdateHighlights(true)
  end

  -- Update highlighted lines
  function CPULib.DebugUpdateHighlights(dontForcePosition)
    if ZCPU_Editor then
      -- Highlight current position
	  local xeip = (CPULib.Debugger.Variables.IP or 0) + (CPULib.Debugger.Variables.CS or 0)
      local currentPosition = CPULib.Debugger.PositionByPointer[xeip]

      -- Clear all highlighted lines
      for tab=1,ZCPU_Editor:GetNumTabs() do
        ZCPU_Editor:GetEditor(tab):ClearHighlightedLines()
      end
		
      if currentPosition then
        local textEditor = CPULib.SelectTab(ZCPU_Editor,currentPosition.File)
        if textEditor then
          textEditor:HighlightLine(currentPosition.Line,130,0,0,255)
          if not dontForcePosition then
            textEditor:SetCaret({currentPosition.Line,1}) --currentPosition.Col
          end
        end
      end

      -- Highlight breakpoints
      for key,breakpoint in pairs(CPULib.Debugger.Breakpoint) do
        local line = tonumber(string.sub(key,1,(string.find(key,":") or 0) - 1)) or 0
        local file = string.sub(key,  (string.find(key,":") or 0) + 1)

        local textEditor = CPULib.SelectTab(ZCPU_Editor,file)
        if textEditor then
          if currentPosition and (currentPosition.Line == line) then
            if breakpoint == true then
              textEditor:HighlightLine(line,130,70,20,255)
            else
              textEditor:HighlightLine(line,130,20,70,255)
            end
          else
            if breakpoint == true then
              textEditor:HighlightLine(line,0,70,20,255)
            else
              textEditor:HighlightLine(line,0,20,70,255)
            end
          end
        end
      end
    end
  end

  ------------------------------------------------------------------------------
  -- Debug data arrived from server
  net.Receive("CPULib.DebugData.Registers", function(len, ply)
    CPULib.Debugger.Variables.IP   = net.ReadFloat()
    CPULib.Debugger.Variables.EAX  = net.ReadFloat()
    CPULib.Debugger.Variables.EBX  = net.ReadFloat()
    CPULib.Debugger.Variables.ECX  = net.ReadFloat()
    CPULib.Debugger.Variables.EDX  = net.ReadFloat()
    CPULib.Debugger.Variables.ESI  = net.ReadFloat()
    CPULib.Debugger.Variables.EDI  = net.ReadFloat()
    CPULib.Debugger.Variables.EBP  = net.ReadFloat()
    CPULib.Debugger.Variables.ESP  = net.ReadFloat()
    
	CPULib.Debugger.Variables.TIMER = net.ReadFloat()
	CPULib.Debugger.Variables.TMR = net.ReadFloat()
	CPULib.Debugger.Variables.CMPR = net.ReadFloat()
	
    CPULib.Debugger.Variables.CS  = net.ReadFloat()
    CPULib.Debugger.Variables.SS  = net.ReadFloat()
    CPULib.Debugger.Variables.DS  = net.ReadFloat()
    CPULib.Debugger.Variables.ES  = net.ReadFloat()
    CPULib.Debugger.Variables.GS  = net.ReadFloat()
    CPULib.Debugger.Variables.FS  = net.ReadFloat()
    CPULib.Debugger.Variables.KS  = net.ReadFloat()
    CPULib.Debugger.Variables.LS  = net.ReadFloat()

    for reg=0,31 do
      CPULib.Debugger.Variables["R"..reg]  = net.ReadFloat()
    end
	
    CPULib.DebugUpdateHighlights()
  end)
  
  net.Receive("CPULib.DebugData.Stack", function(len, ply)
	local i
	local count = net.ReadUInt(16)
	for i = 1,count do
	  CPULib.Debugger.Stack[i] = net.ReadFloat()
	end
  end)

  net.Receive("CPULib.DebugData.Variables", function(len, ply)
    local startIndex = net.ReadInt(16)
    for varIdx = startIndex,startIndex+59 do
      if CPULib.Debugger.MemoryVariableByIndex[varIdx] then
        CPULib.Debugger.Variables[CPULib.Debugger.MemoryVariableByIndex[varIdx]] = net.ReadFloat()
      end
    end
  end)

  net.Receive("CPULib.DebugData.InterruptText", function(len, ply)
    local interruptNo,interruptParameter = net.ReadFloat(),net.ReadFloat()
    CPULib.InterruptText = "Error #"..interruptNo.. " ["..interruptParameter.."]"
  end)

  ------------------------------------------------------------------------------
  -- Show ZCPU/ZGPU documentation
  CPULib.HandbookWindow = nil

  function CPULib.ShowDocumentation(platform)
    local w = ScrW() * 2/3
    local h = ScrH() * 2/3
    local browserWindow = vgui.Create("DFrame")
    browserWindow:SetTitle("Documentation")
    browserWindow:SetPos((ScrW() - w)/2, (ScrH() - h)/2)
    browserWindow:SetSize(w,h)
    browserWindow:MakePopup()

    local browser = vgui.Create("DHTML",browserWindow)
    browser:SetPos(10, 25)
    browser:SetSize(w - 20, h - 35)

    browser:OpenURL("http://wiki.wiremod.com/wiki/Category:ZCPU_Handbook")
  end
end







if SERVER then
  util.AddNetworkString("CPULib.ServerUploading")
  util.AddNetworkString("CPULib.DebugData.Stack")
  util.AddNetworkString("CPULib.DebugData.Registers")
  util.AddNetworkString("CPULib.DebugData.Variables")
  util.AddNetworkString("CPULib.DebugData.InterruptText")
  
  ------------------------------------------------------------------------------
  -- Data received from server
  CPULib.DataBuffer = {}

  ------------------------------------------------------------------------------
  -- Set this entity as a receiver for networked upload
  function CPULib.SetUploadTarget(entity,player)
    CPULib.DataBuffer[player:UserID()] = {
      Entity = entity,
      Player = player,
      Data = {},
    }
  end

  util.AddNetworkString("wire_cpulib_bufferstart")
  net.Receive("wire_cpulib_bufferstart", function(netlen, player)
    local Buffer = CPULib.DataBuffer[player:UserID()]
    if (not Buffer) or (Buffer.Player ~= player) then return end
    if not IsValid(Buffer.Entity) then return end

    net.Start("CPULib.ServerUploading") net.WriteBit(true) net.Send(player)
    if Buffer.Entity:GetClass() == "gmod_wire_cpu" then
      Buffer.Entity:SetCPUName(net.ReadString())
    end
  end)

  -- Concommand to send a single stream of bytes
  util.AddNetworkString("wire_cpulib_buffer")
  net.Receive("wire_cpulib_buffer", function(netlen, player)
    local Buffer = CPULib.DataBuffer[player:UserID()]
    if (not Buffer) or (Buffer.Player ~= player) then return end
    if not Buffer.Entity then return end

    for _ = 1, net.ReadUInt(16) do
      Buffer.Data[net.ReadUInt(24)] = net.ReadDouble()
    end

    if net.ReadBit() ~= 0 then -- We're done!
      CPULib.DataBuffer[player:UserID()] = nil
      net.Start("CPULib.ServerUploading") net.WriteBit(false) net.Send(player)

      if Buffer.Entity:GetClass() == "gmod_wire_cpu" then
        Buffer.Entity:FlashData(Buffer.Data)
      elseif Buffer.Entity:GetClass() == "gmod_wire_dhdd" then
        for k,v in pairs(Buffer.Data) do
          Buffer.Entity.Memory[k] = v
        end
        Buffer.Entity:ShowOutputs()
      elseif Buffer.Entity:GetClass() == "gmod_wire_gpu" then
        Buffer.Entity:WriteCell(65535,0)
        if Buffer.Entity.WriteCell then
          for k,v in pairs(Buffer.Data) do
            Buffer.Entity:WriteCell(k,v)
          end
        end
        Buffer.Entity:WriteCell(65535,Buffer.Entity.Clk)
        Buffer.Entity:WriteCell(65534,1)
      else
        if Buffer.Entity.WriteCell then
          for k,v in pairs(Buffer.Data) do
            Buffer.Entity:WriteCell(k,v)
          end
        end
      end
    end
  end)

  ------------------------------------------------------------------------------
  -- Players and corresponding entities (for the debugger)
  CPULib.DebuggerData = {}

  ------------------------------------------------------------------------------
  -- Attach a debugger
  function CPULib.AttachDebugger(entity,player)
    if entity then
      entity.BreakpointInstructions = {}
	  entity.RunTillBreakpointInstruction = -1
      entity.OnBreakpointInstruction = function(XEIP)
        CPULib.SendDebugData(entity.VM,CPULib.DebuggerData[player:UserID()].MemPointers,player)
		if entity.RunTillBreakpointInstruction > -1 then
			entity.BreakpointInstructions[entity.RunTillBreakpointInstruction] = nil
			entity.RunTillBreakpointInstruction = -1
		end
      end
      entity.OnVMStep = function()
        if SysTime() - CPULib.DebuggerData[player:UserID()].PreviousUpdateTime > 0.2 then
          CPULib.DebuggerData[player:UserID()].PreviousUpdateTime = SysTime()

          -- Send a fake update that messes up line pointer, updates registers
          local tempIP = entity.VM.IP
          entity.VM.IP = INVALID_BREAKPOINT_IP
          CPULib.SendDebugData(entity.VM,nil,player)
          entity.VM.IP = tempIP
        end
      end
      if not entity.VM.BaseJump then
        entity.VM.BaseJump = entity.VM.Jump
        entity.VM.Jump = function(VM,IP,CS)
          VM:BaseJump(IP,CS)
          entity.ForceLastInstruction = true
        end
        entity.VM.BaseInterrupt = entity.VM.Interrupt
        entity.VM.Interrupt = function(VM,interruptNo,interruptParameter,isExternal,cascadeInterrupt)
          VM:BaseInterrupt(interruptNo,interruptParameter,isExternal,cascadeInterrupt)
          if interruptNo < 27 then
            CPULib.DebugLogInterrupt(player,interruptNo,interruptParameter,isExternal,cascadeInterrupt)
            CPULib.SendDebugData(entity.VM,CPULib.DebuggerData[player:UserID()].MemPointers,player)
          end
        end
      end
    else
      if CPULib.DebuggerData[player:UserID()] then
        if CPULib.DebuggerData[player:UserID()].Entity and
           CPULib.DebuggerData[player:UserID()].Entity.VM and
           CPULib.DebuggerData[player:UserID()].Entity.VM.BaseInterrupt then

          CPULib.DebuggerData[player:UserID()].Entity.BreakpointInstructions = nil
          if CPULib.DebuggerData[player:UserID()].Entity.VM.BaseJump then
            CPULib.DebuggerData[player:UserID()].Entity.VM.Jump = CPULib.DebuggerData[player:UserID()].Entity.VM.BaseJump
            CPULib.DebuggerData[player:UserID()].Entity.VM.Interrupt = CPULib.DebuggerData[player:UserID()].Entity.VM.BaseInterrupt
            CPULib.DebuggerData[player:UserID()].Entity.VM.BaseJump = nil
            CPULib.DebuggerData[player:UserID()].Entity.VM.BaseInterrupt = nil
          end
        end
      end
    end

    CPULib.DebuggerData[player:UserID()] = {
      Entity = entity,
      Player = player,
      MemPointers = {},
      PreviousUpdateTime = SysTime(),
    }
  end

  -- Log debug interrupt
  function CPULib.DebugLogInterrupt(player,interruptNo,interruptParameter,isExternal,cascadeInterrupt)
	net.Start("CPULib.DebugData.InterruptText")
	net.WriteFloat(interruptNo)
	net.WriteFloat(interruptParameter)
	net.Send(player)
  end

  -- Send debug log entry to client
  function CPULib.SendDebugLogEntry(player,text)
--
  end

  -- Send debugging data to client
  function CPULib.SendDebugData(VM,MemPointers,Player,onlyMemPointers)
    if not onlyMemPointers then
      net.Start("CPULib.DebugData.Registers")
        net.WriteFloat(VM.IP)
        net.WriteFloat(VM.EAX)
        net.WriteFloat(VM.EBX)
        net.WriteFloat(VM.ECX)
        net.WriteFloat(VM.EDX)
        net.WriteFloat(VM.ESI)
        net.WriteFloat(VM.EDI)
        net.WriteFloat(VM.EBP)
        net.WriteFloat(VM.ESP)
		
        net.WriteFloat(VM.TIMER)
        net.WriteFloat(VM.TMR)
        net.WriteFloat(VM.CMPR)
		
        net.WriteFloat(VM.CS)
        net.WriteFloat(VM.SS)
        net.WriteFloat(VM.DS)
        net.WriteFloat(VM.ES)
        net.WriteFloat(VM.GS)
        net.WriteFloat(VM.FS)
        net.WriteFloat(VM.KS)
        net.WriteFloat(VM.LS)

        for reg = 0,31 do
          net.WriteFloat(VM["R"..reg])
        end
      net.Send(Player)
    end
	
	if MemPointers then
		net.Start("CPULib.DebugData.Stack")
		local i
		local ramSize = VM.RAMSize
		local count = 1536
		net.WriteUInt(count, 16)
		for i = 1,count do
			local stackAddr = VM.ESP + VM.SS + i
			local val = 0
			if stackAddr >= 0 and stackAddr < ramSize then
				local oldTMR = VM.TMR
				val = VM:ReadCell(stackAddr)
				VM.TMR = oldTMR
			end
			net.WriteFloat(val)
		end
		net.Send(Player)
	end

    if MemPointers then
      for msgIdx=0,math.floor(#MemPointers/60) do
        net.Start("CPULib.DebugData.Variables")
          net.WriteInt(msgIdx*60, 16)
          for varIdx=msgIdx*60,msgIdx*60+59 do
            if MemPointers[varIdx] then
			  local oldTMR = VM.TMR
              net.WriteFloat(VM:ReadCell(MemPointers[varIdx]))
			  VM.TMR = oldTMR
            end
          end
        net.Send(Player)
      end
    end
  end

  -- Concommand to step forward
  concommand.Add("wire_cpulib_debugstep", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end

    if not args[1] then -- Step forward
	
	  -- Doesn't work, skips like 9 instructions at a time.
      --[[ Data.Entity.VM:Step(1)
      Data.Entity.VMStopped = true
	  Data.Entity:NextThink(CurTime()) ]]
	  
	  -- Same as below, not sure what LastInstruction means, but setting it to 0 makes it step one instruction.
	  -- TODO: fix-me: This increases TMR by like a hundred thousand per step.
	  Data.Entity.Clk = false
      Data.Entity.VMStopped = false
      Data.Entity:NextThink(CurTime())

      Data.Entity.LastInstruction = 0
      Data.Entity.OnLastInstruction = function()
        Data.Entity.LastInstruction = nil
        Data.Entity.OnLastInstruction = nil
        CPULib.SendDebugData(Data.Entity.VM,Data.MemPointers,Data.Player)
      end
	  
	  
	  
    else -- Run until instruction
	  Data.Entity.Clk = false
      Data.Entity.VMStopped = false
      Data.Entity:NextThink(CurTime())

      Data.Entity.LastInstruction = tonumber(args[1]) or 0
      Data.Entity.OnLastInstruction = function()
        Data.Entity.LastInstruction = nil
        Data.Entity.OnLastInstruction = nil
        CPULib.SendDebugData(Data.Entity.VM,Data.MemPointers,Data.Player)
      end
    end
    CPULib.SendDebugData(Data.Entity.VM,Data.MemPointers,Data.Player)
  end)

  -- Concommand to run till breakpoint
  concommand.Add("wire_cpulib_debugrun", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end

    -- Send a fake update that messes up line pointer
    local tempIP = Data.Entity.VM.IP
    Data.Entity.VM.IP = INVALID_BREAKPOINT_IP
    CPULib.SendDebugData(Data.Entity.VM,nil,Data.Player)
    Data.Entity.VM.IP = tempIP

	Data.Entity.VMStopped = false
    Data.Entity.Clk = true
    Data.Entity:NextThink(CurTime())
  end)

  -- Concommand to reset
  concommand.Add("wire_cpulib_debugreset", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end

	Data.Entity.Clk = false
    Data.Entity.VM:Reset()
	Data.Entity.VMStopped = true
    CPULib.SendDebugData(Data.Entity.VM,Data.MemPointers,Data.Player)
  end)

  -- Concommand to add a variable
  concommand.Add("wire_cpulib_debugvar", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end

    Data.MemPointers[tonumber(args[1]) or 0] = tonumber(args[2])
    CPULib.SendDebugData(Data.Entity.VM,Data.MemPointers,Data.Player,true)
  end)

  -- Concommand to set a debug breakpoint
  concommand.Add("wire_cpulib_debugbreakpoint", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end

    if tonumber(args[2]) == 0 then
      Data.Entity.BreakpointInstructions[tonumber(args[1]) or 0] = nil
    else
      Data.Entity.BreakpointInstructions[tonumber(args[1]) or 0] = true
    end
  end)
  
  -- Concommand to run till line
  concommand.Add("wire_cpulib_debugruntill", function(player, command, args)
    local Data = CPULib.DebuggerData[player:UserID()]
    if (not Data) or (Data.Player ~= player) then return end
    if not IsValid(Data.Entity) then return end
	if not args[1] then return end

	local ptr = tonumber(args[1])
    Data.Entity.BreakpointInstructions[ptr] = true
	Data.Entity.RunTillBreakpointInstruction = ptr
	
	-- TODO: Refactor into a function (Used for Run command as well)?
    -- Send a fake update that messes up line pointer
    local tempIP = Data.Entity.VM.IP
    Data.Entity.VM.IP = INVALID_BREAKPOINT_IP
    CPULib.SendDebugData(Data.Entity.VM,nil,Data.Player)
    Data.Entity.VM.IP = tempIP

	Data.Entity.VMStopped = false
    Data.Entity.Clk = true
    Data.Entity:NextThink(CurTime())
  end)
else
  -- CLIENT
  -- Concommand to step forward
  concommand.Add("wire_cpulib_debugstep2", function(player, command, args)
	local xeip = (CPULib.Debugger.Variables.CS or 0) + (CPULib.Debugger.Variables.IP or 0)
	local currentPosition = CPULib.Debugger.PositionByPointer[xeip]
	if currentPosition then
		local linePointers = CPULib.Debugger.PointersByLine[currentPosition.Line .. ":" .. currentPosition.File]
		if linePointers then -- Run till end of line
			RunConsoleCommand("wire_cpulib_debugstep", linePointers[2])
		else -- Run just once
			RunConsoleCommand("wire_cpulib_debugstep")
		end
	else -- Run just once
		RunConsoleCommand("wire_cpulib_debugstep")
	end
	-- Reset interrupt text
	CPULib.InterruptText = nil
  end)
end


--------------------------------------------------------------------------------
-- Create a new virtual machine
--------------------------------------------------------------------------------
function CPULib.VirtualMachine()
  -- Create new instance of the VM
  include("wire/zvm/zvm_core.lua")

  -- Remove from global scope
  local newVM = ZVM
  ZVM = nil
  return newVM
end


--------------------------------------------------------------------------------
-- Generate a serial number
--------------------------------------------------------------------------------
local sessionBase, sessionDate
function CPULib.GenerateSN(entityType)
  local currentDate = os.date("*t")

  local SNDate = (currentDate.year-2007)*500+(currentDate.yday)
  if (not sessionBase) or (SNDate ~= sessionDate) then
    sessionBase = math.floor(math.random()*99999)
    sessionDate = SNDate
  else
    sessionBase = sessionBase + 1
  end

  if entityType == "CPU" then
    return sessionBase + 100000 + SNDate*1000000
  elseif entityType == "SPU" then
    return sessionBase + 200000 + SNDate*1000000
  elseif entityType == "GPU" then
    return sessionBase + 300000 + SNDate*1000000
  elseif entityType == "UNK" then
    return sessionBase + 700000 + SNDate*1000000
  end
end


--------------------------------------------------------------------------------
-- Get device type
--------------------------------------------------------------------------------
local DeviceType = {
  ["gmod_wire_extbus"]        = 2,
  ["gmod_wire_addressbus"]    = 3,
  ["gmod_wire_cpu"]           = 4,
  ["gmod_wire_gpu"]           = 5,
  ["gmod_wire_spu"]           = 6,
  ["gmod_wire_hdd"]           = 7,
  ["gmod_wire_dhdd"]          = 8,
  ["gmod_wire_datarate"]      = 9,
  ["gmod_wire_cd_ray"]        = 10,
  ["gmod_wire_consolescreen"] = 11,
  ["gmod_wire_digitalscreen"] = 12,
  ["gmod_wire_dataplug"]      = 13,
  ["gmod_wire_datasocket"]    = 14,
  ["gmod_wire_keyboard"]      = 15,
  ["gmod_wire_oscilloscope"]  = 16,
  ["gmod_wire_soundemitter"]  = 17,
  ["gmod_wire_value"]         = 18,
  ["gmod_wire_dataport"]      = 19,
  ["gmod_wire_gate"]          = 20,
}

function CPULib.GetDeviceType(class)
  return DeviceType[class] or 1
end





--------------------------------------------------------------------------------
-- Columns in the instruction set reference table:
--  Opc - Instruction number
--  Mnemonic - Symbolic mnemonic (uppercase). Can be "RESERVED"
--  Ops - Number of operands
--  Version - Minimum CPU version required
--  Flags - Several or none of the following flags:
--    W1: single-operand opcode which writes 1st operand
--    R0: runlevel 0 opcode (privileged opcode)
--    OB: obsolete/should not be used
--    UB: unconditional branching instruction
--    CB: conditional branching instruction
--    TR: trigonometric syntax operand
--    OL: old mnemonic for the instruction
--    BL: instruction supports block prefix
--  Op1 - operand 1 name
--  Op2 - operand 2 name

-- Possible operand names:
-- X,Y: arbitrary integer or floating-point value
-- PTR: 48-bit pointer into memory
-- CS: 48-bit pointer into memory, new value of CS segment
-- IDX: unsigned integer index into internal processor table
-- PAGE: unsigned integer page number (each page is 128 bytes)
-- PORT: unsigned 47-bit integer port number
-- BIT: integer between 0 and 47
-- INTR: interrupt nubmer (integer between 0 and 255)
-- SIZE: unsigned 47-bit integer memory block size
--
-- COLOR: 4-byte color
-- VEC2F: 2-byte vector
--
-- INT: 48-bit signed integer

CPULib.InstructionTable = {}
CPULib.MnemonicToInstructionTable = {}
local W1,R0,OB,UB,CB,TR,OL,BL = 1,2,4,8,16,32,64,128

local function Bit(x,n) return (math.floor(x / n) % 2) == 1 end
local function Entry(Set,Opc,Mnemonic,Ops,Version,Flags,Op1,Op2,Reference)
  table.insert(CPULib.InstructionTable,
    { Set = Set,
      Opcode = Opc,
      Mnemonic = Mnemonic,
      OperandCount = Ops,
      MinimumVersion = Version,
      Operand1 = Op1,
      Operand2 = Op2,
      Reference = Reference,

      WritesFirstOperand = Bit(Flags,W1),
      Privileged = Bit(Flags,R0),
      Obsolete = Bit(Flags,OB),
      UnconditionalBranching = Bit(Flags,UB),
      ConditionalBranching = Bit(Flags,CB),
      Trigonometric = Bit(Flags,TR),
      Old = Bit(Flags,OL),
      BlockPrefix = Bit(Flags,BL),
    })
  CPULib.MnemonicToInstructionTable[Mnemonic] = #CPULib.InstructionTable
end
local function CPU(...) Entry("CPU",...) end
local function GPU(...) Entry("GPU",...) end
local function VEX(...) Entry("VEX",...) end
local function SPU(...) Entry("SPU",...) end


-------------------------------------------------------------------------------------------------------------------------------------------------
-- Zyelios CPU/GPU/SPU instruction set reference table
-------------------------------------------------------------------------------------------------------------------------------------------------
--- Opc  Mnemonic ------- Ops  Version  Flags ---- Op1 ---- Op2 ---- Reference ------------------------------------------------------------------
CPU(000, "RESERVED",      0,   0.00,    0,         "",      "",      "Stop processor execution")
CPU(001, "JNE",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not equal")
CPU(001, "JNZ",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not zero")
CPU(002, "JMP",           1,   1.00,    UB,        "PTR",   "",      "Jump to PTR")
CPU(003, "JG",            1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is greater")
CPU(003, "JNLE",          1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not less or equal")
CPU(004, "JGE",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is greater or equal")
CPU(004, "JNL",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not less")
CPU(005, "JL",            1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is less")
CPU(005, "JNGE",          1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not greater or equal")
CPU(006, "JLE",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is less or equal")
CPU(006, "JNG",           1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is not greater")
CPU(007, "JE",            1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is equal")
CPU(007, "JZ",            1,   1.00,    CB,        "PTR",   "",      "Jump to PTR if result is zero")
CPU(008, "CPUID",         1,   1.00,    0,         "IDX",   "",      "Write processor information variable IDX into EAX register")
CPU(009, "PUSH",          1,   1.00,    0,         "X",     "",      "Push X onto processor stack")
---- Dec 1 --------------------------------------------------------------------------------------------------------------------------------------
CPU(010, "ADD",           2,   1.00,    0,         "X",     "Y",     "X = X + Y")
CPU(011, "SUB",           2,   1.00,    0,         "X",     "Y",     "X = X - Y")
CPU(012, "MUL",           2,   1.00,    0,         "X",     "Y",     "X = X * Y")
CPU(013, "DIV",           2,   1.00,    0,         "X",     "Y",     "X = X / Y")
CPU(014, "MOV",           2,   1.00,    0,         "X",     "Y",     "X = Y")
CPU(015, "CMP",           2,   1.00,    0,         "X",     "Y",     "Compare X and Y. Use with conditional branching instructions")
CPU(016, "RD",            2,   1.00,    R0+OB,     "X",     "PTR",   "Read value from memory by pointer PTR")
CPU(017, "WD",            2,   1.00,    R0+OB,     "PTR",   "Y",     "Write value to memory by pointer PTR")
CPU(018, "MIN",           2,   1.00,    0,         "X",     "Y",     "Set X to smaller value out of X and Y")
CPU(019, "MAX",           2,   1.00,    0,         "X",     "Y",     "Set X to bigger value out of X and Y")
---- Dec 2 --------------------------------------------------------------------------------------------------------------------------------------
CPU(020, "INC",           1,   1.00,    W1,        "X",     "",      "Increase X by one")
CPU(021, "DEC",           1,   1.00,    W1,        "X",     "",      "Decrease X by one")
CPU(022, "NEG",           1,   1.00,    W1,        "X",     "",      "Change sign of X")
CPU(023, "RAND",          1,   1.00,    W1,        "X",     "",      "Set X to random value")
CPU(024, "LOOP",          1,   2.00,    CB,        "PTR",   "",      "If ECX is not set to 0, decrease ECX and jump to PTR")
CPU(024, "LOOPC",         1,  10.00,    CB,        "PTR",   "",      "If ECX is not set to 0, decrease ECX and jump to PTR")
CPU(025, "LOOPA",         1,   2.00,    CB,        "PTR",   "",      "If EAX is not set to 0, decrease EAX and jump to PTR")
CPU(026, "LOOPB",         1,   2.00,    CB,        "PTR",   "",      "If EBX is not set to 0, decrease EBX and jump to PTR")
CPU(027, "LOOPD",         1,   2.00,    CB,        "PTR",   "",      "If EDX is not set to 0, decrease EDX and jump to PTR")
CPU(028, "SPG",           1,   2.00,    R0,        "PAGE",  "",      "Make PAGE readonly")
CPU(029, "CPG",           1,   2.00,    R0,        "PAGE",  "",      "Make PAGE readable and writeable")
---- Dec 3---------------------------------------------------------------------------------------------------------------------------------------
CPU(030, "POP",           1,   1.00,    0,         "X",     "",      "Pop value off stack and write it into X")
CPU(031, "CALL",          1,   1.00,    UB,        "PTR",   "",      "Call subroutine by address PTR")
CPU(032, "BNOT",          1,   1.00,    W1,        "INT",   "",      "Flip all bits in the integer number")
CPU(033, "FINT",          1,   1.00,    W1,        "X",     "",      "Force X to be an integer value")
CPU(034, "FRND",          1,   1.00,    W1,        "X",     "",      "Round X to the nearest integer value")
CPU(034, "RND",           1,   1.00,    W1+OL,     "X",     "",      "FRND")
CPU(035, "FFRAC",         1,   1.00,    W1,        "X",     "",      "Remove integer part of the X, leaving only the fractional part")
CPU(036, "FINV",          1,   1.00,    W1,        "X",     "",      "X = 1 / X")
CPU(037, "HALT",          1,   1.00,    OB,        "PORT",  "",      "Halt processor execution until PORT is written to")
CPU(038, "FSHL",          1,   2.00,    W1,        "X",     "",      "Multiply X by 2 (does not floor)")
CPU(039, "FSHR",          1,   2.00,    W1,        "X",     "",      "Divide X by 2 (does not floor)")
---- Dec 4 --------------------------------------------------------------------------------------------------------------------------------------
CPU(040, "RET",           0,   1.00,    UB,        "",      "",      "Return from a subroutine")
CPU(041, "IRET",          0,   2.00,    UB,        "",      "",      "Return from an interrupt")
CPU(042, "STI",           0,   2.00,    R0,        "",      "",      "Enable interrupt handling")
CPU(043, "CLI",           0,   2.00,    R0,        "",      "",      "Disable interrupt handling")
CPU(044, "STP",           0,   2.00,    R0+OB,     "",      "",      "Enable protected mode")
CPU(045, "CLP",           0,   2.00,    R0+OB,     "",      "",      "Disable protected mode")
CPU(046, "RESERVED",      0,   0.00,    R0,        "",      "",      "")
CPU(047, "RETF",          0,   1.00,    UB,        "",      "",      "Return from a far subroutine call")
CPU(048, "STEF",          0,   4.00,    R0,        "",      "",      "Enable extended mode")
CPU(049, "CLEF",          0,   4.00,    R0,        "",      "",      "Disable extended mode")
---- Dec 5 --------------------------------------------------------------------------------------------------------------------------------------
CPU(050, "AND",           2,   1.00,    0,         "X",     "Y",     "Logical AND between X and Y")
CPU(051, "OR",            2,   1.00,    0,         "X",     "Y",     "Logical OR between X and Y")
CPU(052, "XOR",           2,   1.00,    0,         "X",     "Y",     "Logical XOR between X and Y")
CPU(053, "FSIN",          2,   1.00,    TR,        "X",     "Y",     "Write sine of X to Y")
CPU(054, "FCOS",          2,   1.00,    TR,        "X",     "Y",     "Write cosine of X to Y")
CPU(055, "FTAN",          2,   1.00,    TR,        "X",     "Y",     "Write tangent of X to Y")
CPU(056, "FASIN",         2,   1.00,    TR,        "X",     "Y",     "Write arcsine of X to Y")
CPU(057, "FACOS",         2,   1.00,    TR,        "X",     "Y",     "Write arccosine of X to Y")
CPU(058, "FATAN",         2,   1.00,    TR,        "X",     "Y",     "Write arctangent of X to Y")
CPU(059, "MOD",           2,   2.00,    0,         "X",     "Y",     "Write remainder of X/Y to Y")
---- Dec 6 --------------------------------------------------------------------------------------------------------------------------------------
CPU(060, "BIT",           2,   2.00,    0,         "INT",   "BIT",   "Test whether BIT of X is set. Use with conditional branching instructions")
CPU(061, "SBIT",          2,   2.00,    0,         "INT",   "BIT",   "Set BIT of X")
CPU(062, "CBIT",          2,   2.00,    0,         "INT",   "BIT",   "Clear BIT of X")
CPU(063, "TBIT",          2,   2.00,    0,         "INT",   "BIT",   "Toggle BIT of X")
CPU(064, "BAND",          2,   2.00,    0,         "INT",   "INT",   "Write result of binary AND between operands")
CPU(065, "BOR",           2,   2.00,    0,         "INT",   "INT",   "Write result of binary OR between operands")
CPU(066, "BXOR",          2,   2.00,    0,         "INT",   "INT",   "Write result of binary XOR between operands")
CPU(067, "BSHL",          2,   2.00,    0,         "INT",   "X",     "Shift bits of INT left by X")
CPU(068, "BSHR",          2,   2.00,    0,         "INT",   "X",     "Shift bits of INT right by X")
CPU(069, "JMPF",          2,   2.00,    UB,        "PTR",   "CS",    "Jump to PTR in code segment CS")
---- Dec 7 --------------------------------------------------------------------------------------------------------------------------------------
CPU(070, "NMIINT",        1,   4.00,    R0+OL,     "INTR",  "",      "EXTINT")
CPU(070, "EXTINT",        1,  10.00,    R0,        "INTR",  "",      "Call interrupt INTR as an external interrupt")
CPU(071, "CNE",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not equal")
CPU(071, "CNZ",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not zero")
CPU(072, "RESERVED",      1,   0.00,    0,         "",      "",      "")
CPU(073, "CG",            1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is greater")
CPU(073, "CNLE",          1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not less or equal")
CPU(074, "CGE",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is greater or equal")
CPU(074, "CNL",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not less")
CPU(075, "CL",            1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is less")
CPU(075, "CNGE",          1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not greater or equal")
CPU(076, "CLE",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is less or equal")
CPU(076, "CNG",           1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is not greater")
CPU(077, "CE",            1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is equal")
CPU(077, "CZ",            1,   2.00,    CB,        "PTR",   "",      "Call subrotine if result is zero")
CPU(078, "MCOPY",         1,   2.00,    BL,        "INT",   "",      "Copy INT bytes from array pointed by ESI to EDI")
CPU(079, "MXCHG",         1,   2.00,    BL,        "INT",   "",      "Swap INT bytes between two arrays pointed by ESI and EDI")
---- Dec 8 --------------------------------------------------------------------------------------------------------------------------------------
CPU(080, "FPWR",          2,   2.00,    0,         "X",     "Y",     "Raise X to power Y")
CPU(081, "XCHG",          2,   2.00,    0,         "X",     "Y",     "Swap X and Y")
CPU(082, "FLOG",          2,   2.00,    OL,        "X",     "Y",     "FLN")
CPU(082, "FLN",           2,  10.00,    0,         "X",     "Y",     "Write logarithm (base e) of Y to X")
CPU(083, "FLOG10",        2,   2.00,    0,         "X",     "Y",     "Write logarithm (base 10) of Y to X")
CPU(084, "IN",            2,   2.00,    0,         "X",     "PORT",  "Input value from PORT to X")
CPU(085, "OUT",           2,   2.00,    0,         "PORT",  "Y",     "Write X to PORT")
CPU(086, "FABS",          2,   2.00,    TR,        "X",     "Y",     "Write absolute value of Y to X")
CPU(087, "FSGN",          2,   2.00,    TR,        "X",     "Y",     "Write sign of Y to X")
CPU(088, "FEXP",          2,   2.00,    TR,        "X",     "Y",     "Write exponent of Y to X")
CPU(089, "CALLF",         2,   2.00,    UB,        "PTR",   "CS",    "Call subroutine by offset PTR in code segment CS")
---- Dec 9 --------------------------------------------------------------------------------------------------------------------------------------
CPU(090, "FPI",           1,   2.00,    W1,        "X",     "",      "Set X to precise value of PI (3.1415926..)")
CPU(091, "FE",            1,   2.00,    W1,        "X",     "",      "Set X to precise value of E (2.7182818..)")
CPU(092, "INT",           1,   2.00,    0,         "INTR",  "",      "Call interrupt INTR")
CPU(093, "TPG",           1,   2.00,    0,         "PAGE",  "",      "Test PAGE. Use branching instructions to test for zero on failure, non-zero if test passed.")
CPU(094, "FCEIL",         1,   2.00,    W1,        "X",     "",      "Rounds X up to the next integer")
CPU(095, "ERPG",          1,   2.00,    R0,        "PAGE",  "",      "Erase ROM page")
CPU(096, "WRPG",          1,   2.00,    R0,        "PAGE",  "",      "Copy RAM page into ROM page")
CPU(097, "RDPG",          1,   2.00,    R0,        "PAGE",  "",      "Read ROM page into RAM")
CPU(098, "TIMER",         1,   2.00,    W1,        "X",     "",      "Set X to value of the internal processor timer")
CPU(099, "LIDTR",         1,   2.00,    R0,        "PTR",   "",      "Set interrupt table pointer to PTR")
---- Dec 10 -------------------------------------------------------------------------------------------------------------------------------------
CPU(100, "RESERVED",      1,   0.00,    R0,        "",      "",      "")
CPU(101, "JNER",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not equal")
CPU(101, "JNZR",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not zero")
CPU(102, "JMPR",          1,   3.00,    UB,        "INT",   "",      "Relative jump INT bytes forward")
CPU(103, "JGR",           1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is greater")
CPU(103, "JNLER",         1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not less or equal")
CPU(104, "JGER",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is greater or equal")
CPU(104, "JNLR",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not less")
CPU(105, "JLR",           1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is less")
CPU(105, "JNGER",         1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not greater or equal")
CPU(106, "JLER",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is less or equal")
CPU(106, "JNGR",          1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is not greater")
CPU(107, "JER",           1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is equal")
CPU(107, "JZR",           1,   3.00,    CB,        "INT",   "",      "Relative jump INT bytes forward if result is zero")
CPU(108, "LNEG",          1,   3.00,    W1,        "X",     "",      "Logically negate X")
CPU(109, "RESERVED",      1,   0.00,    R0,        "",      "",      "")
---- Dec 11 -------------------------------------------------------------------------------------------------------------------------------------
CPU(110, "NMIRET",        0,   2.00,    R0+OL,     "",      "",      "EXTRET")
CPU(110, "EXTRET",        0,  10.00,    R0,        "",      "",      "Return from an external interrupt")
CPU(111, "IDLE",          0,   4.00,    R0,        "",      "",      "Skip several processor cycles")
CPU(112, "NOP",           0,   5.00,    0,         "",      "",      "Do nothing")
CPU(113, "RESERVED",      0,   0.00,    0,         "",      "",      "")
CPU(114, "PUSHA",         0,   8.00,    0,         "",      "",      "Push all general purpose registers to stack")
CPU(115, "POPA",          0,   8.00,    0,         "",      "",      "Pop all general purpose registers off stack")
CPU(116, "STD2",          0,  10.00,    R0,        "",      "",      "Enable hardware debug mode")
CPU(117, "LEAVE",         0,  10.00,    0,         "",      "",      "Leave subroutine stack frame")
CPU(118, "STM",           0,  10.00,    R0,        "",      "",      "Enable extended memory mode")
CPU(119, "CLM",           0,  10.00,    R0,        "",      "",      "Disable extended memory mode")
---- Dec 12 -------------------------------------------------------------------------------------------------------------------------------------
CPU(120, "CPUGET",        2,   5.00,    R0,        "X",     "IDX",   "Read internal processor register IDX")
CPU(121, "CPUSET",        2,   5.00,    R0,        "IDX",   "Y",     "Write internal processor register IDX")
CPU(122, "SPP",           2,   5.00,    R0+BL,     "PAGE",  "IDX",   "Set page flag IDX")
CPU(123, "CPP",           2,   5.00,    R0+BL,     "PAGE",  "IDX",   "Clear page flag IDX")
CPU(124, "SRL",           2,   5.00,    R0+BL,     "PAGE",  "INT",   "Set page runlevel to INT")
CPU(125, "CRL",           2,   5.00,    R0,        "X",     "PAGE",  "Write page runlevel to INT")
CPU(126, "LEA",           2,   5.00,    0,         "X",     "Y",     "Load absolute address fetched by operand Y into X")
CPU(127, "BLOCK",         2,   6.00,    0,         "PTR",   "SIZE",  "Make next instruction run on this block")
CPU(128, "CMPAND",        2,   6.00,    0,         "X",     "Y",     "Compare X and Y, and logically combine with result of previous comparsion using AND")
CPU(129, "CMPOR",         2,   6.00,    0,         "X",     "Y",     "Compare X and Y, and logically combine with result of previous comparsion using OR")
---- Dec 13 -------------------------------------------------------------------------------------------------------------------------------------
CPU(130, "MSHIFT",        2,   7.00,    0,         "COUNT", "OFFSET","Shift (and rotate) data pointed by ESI by OFFSET bytes")
CPU(131, "SMAP",          2,   8.00,    R0+BL,     "PAGE1", "PAGE2", "Remap PAGE1 to physical page PAGE2")
CPU(132, "GMAP",          2,   8.00,    R0,        "X",     "PAGE",  "Read what physical page PAGE is mapped to")
CPU(133, "RSTACK",        2,   9.00,    0,         "X",     "IDX",   "Read value from stack at offset IDX (from address SS+IDX)")
CPU(134, "SSTACK",        2,   9.00,    0,         "IDX",   "Y",     "Write value to stack at offset IDX (to address SS+IDX)")
CPU(135, "ENTER",         1,  10.00,    0,         "SIZE",  "",      "Enter stack frame and allocate SIZE bytes on stack for local variables")
CPU(136, "IRETP",         1,   2.00,    R0,        "PTBL",  "",      "Set PTBL, then return from an interrupt")
CPU(137, "EXTRETP",       1,  10.00,    R0,        "PTBL",  "",      "Set PTBL, then return from an external interrupt")
---- Dec 14 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
CPU(140, "EXTRETA",       0,  11.00,    R0,        "",      "",      "Return from an external interrupt and restore R0-R31 registers")
CPU(141, "EXTRETPA",      1,  11.00,    R0,        "PTBL",  "",      "Set PTBL, then return from an external interrupt with restoring R0-R31 registers")
---- Dec 15 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 16 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 17 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 18 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 19 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 20 -- Output buffer control ------------------------------------------------------------------------------------------------------------
GPU(200, "DTEST",         0,    1.0,    0,         "",      "",      "Output a test pattern to screen")
GPU(200, "DRECT_TEST",    0,    0.5,    OL,        "",      "",      "DTEST")
GPU(201, "DEXIT",         0,    0.5,    UB,        "",      "",      "End execution of the current frame")
GPU(201, "DVSYNC",        0,    1.0,    0,         "",      "",      "Wait until next frame (only in asynchronous thread)")
GPU(202, "DCLR",          0,    0.5,    0,         "",      "",      "Clear screen color to black")
GPU(203, "DCLRTEX",       0,    0.5,    0,         "",      "",      "Clear background with texture")
GPU(204, "DVXFLUSH",      0,    0.6,    0,         "",      "",      "Flush current vertex buffer to screen")
GPU(205, "DVXCLEAR",      0,    0.6,    0,         "",      "",      "Clear vertex buffer")
GPU(206, "DSETBUF_VX",    0,    1.0,    0,         "",      "",      "Set frame buffer to vertex output")
GPU(207, "DSETBUF_SPR",   0,    1.0,    0,         "",      "",      "Set frame buffer to sprite buffer")
GPU(207, "DBACKBUF",      0,    1.0,    0,         "",      "",      "Set frame buffer to back buffer")
GPU(208, "DSETBUF_FBO",   0,    1.0,    0,         "",      "",      "Set frame buffer to view buffer")
GPU(208, "DFRONTBUF",     0,    1.0,    0,         "",      "",      "Set frame buffer to front buffer")
GPU(209, "DSWAP",         0,    1.0,    0,         "",      "",      "Copy back buffer to front buffer")
---- Dec 21 -- Pipe controls and one-operand opcodes --------------------------------------------------------------------------------------------
GPU(210, "DVXPIPE",       1,    0.5,    0,         "IDX",   "",      "Set vertex pipe")
GPU(211, "DCVXPIPE",      1,    0.5,    OL,        "IDX",   "",      "DCPIPE")
GPU(211, "DCPIPE",        1,    1.0,    0,         "IDX",   "",      "Set coordinate pipe")
GPU(212, "DENABLE",       1,    0.5,    0,         "IDX",   "",      "Enable parameter")
GPU(213, "DDISABLE",      1,    0.5,    0,         "IDX",   "",      "Disable parameter")
GPU(214, "DCLRSCR",       1,    0.5,    0,         "COLOR", "",      "Clear screen with color")
GPU(215, "DCOLOR",        1,    0.5,    0,         "COLOR", "",      "Set current color")
GPU(216, "DTEXTURE",      1,    1.0,    0,         "IDX",   "",      "Set current texture")
GPU(217, "DSETFONT",      1,    0.5,    0,         "IDX",   "",      "Set current font")
GPU(218, "DSETSIZE",      1,    0.5,    0,         "INT",   "",      "Set font size")
GPU(219, "DMOVE",         1,    0.5,    0,         "VEC2F", "",      "Set drawing position offset")
---- Dec 22 -- Rendering opcodes ----------------------------------------------------------------------------------------------------------------
GPU(220, "DVXDATA_2F",    2,    0.5,    0,         "VEC2F", "IDX",   "Draw a solid 2D polygon (pointer to 2D data, vertex count)")
GPU(220, "DVXPOLY",       2,    0.5,    0,         "VEC2F", "IDX",   "Draw a solid 2D polygon (pointer to 2D data, vertex count)")
GPU(221, "DVXDATA_2F_TEX",2,    0.5,    0,         "VEC2F", "IDX",   "Draw a textured 2D polygon (pointer to 2D data, vertex count)")
GPU(221, "DVXTEXPOLY",    2,    0.5,    0,         "VEC2F", "IDX",   "Draw a textured 2D polygon (pointer to 2D data, vertex count)")
GPU(222, "DVXDATA_3F",    2,    0.5,    0,         "VEC3F", "IDX",   "Draw a solid 3D polygon (pointer to 3D data, vertex count)")
GPU(223, "DVXDATA_3F_TEX",2,    0.5,    0,         "VEC3FT","IDX",   "Draw a textured 3D polygon (pointer to 3D data, vertex count)")
GPU(224, "DVXDATA_3F_WF", 2,    0.5,    0,         "VEC3F", "IDX",   "Draw a wireframe 3D polygon (pointer to 3D data, vertex count)")
GPU(225, "DRECT",         2,    0.5,    0,         "VEC2F", "VEC2F", "Draw a rectangle (by endpoints)")
GPU(226, "DCIRCLE",       2,    0.5,    0,         "VEC2F", "Y",     "Draw a circle with radius Y")
GPU(227, "DLINE",         2,    0.5,    0,         "VEC2F", "VEC2F", "Draw a line")
GPU(228, "DRECTWH",       2,    0.6,    0,         "VEC2F", "VEC2F", "Draw a rectangle (by offset, size)")
GPU(229, "DORECT",        2,    0.5,    0,         "VEC2F", "VEC2F", "Draw an outlined rectangle")
---- Dec 23 -- Additional rendering opcodes -----------------------------------------------------------------------------------------------------
GPU(230, "DTRANSFORM2F",  2,    0.5,    0,         "VEC2F", "VEC2F", "Transform vector and write it to first operand")
GPU(231, "DTRANSFORM3F",  2,    0.5,    0,         "VEC3F", "VEC3F", "Transform vector and write it to first operand")
GPU(232, "DSCRSIZE",      2,    0.5,    0,         "X",     "Y",     "Set screen size")
GPU(233, "DROTATESCALE",  2,    0.5,    0,         "X",     "Y",     "Rotate by X, scale by Y")
GPU(234, "DORECTWH",      2,    0.5,    0,         "VEC2F", "VEC2F", "Draw an outlined rectangle by width/height")
GPU(235, "DCULLMODE",     2,    0.7,    0,         "IDX",   "IDX",   "Set cullmode and lighting mode")
--GPU(236, "DARRAY",        2,    1.0,    0,         "VEC2F", "STRUCT","Draw an array of pixels")
--GPU(237, "DDTERMINAL",    2,    1.0,    0,         "VEC2F", "STRUCT","Draw a console screen/terminal window")
GPU(238, "DPIXEL",        2,    1.0,    0,         "VEC2F", "COLOR", "Draw a pixel to screen")
GPU(239, "RESERVED",      2,    0.0,    0,         "",      "",      "")
---- Dec 24 -- Text output and lighting ---------------------------------------------------------------------------------------------------------
GPU(240, "DWRITE",        2,    0.5,    0,         "VEC2F", "STRING","Write a string")
GPU(241, "DWRITEI",       2,    0.5,    0,         "VEC2F", "INT",   "Write an integer value")
GPU(242, "DWRITEF",       2,    0.5,    0,         "VEC3F", "Y",     "Write a float value")
GPU(243, "DENTRYPOINT",   2,    0.5,    0,         "IDX",   "PTR",   "Set entry point")
GPU(244, "DSETLIGHT",     2,    0.6,    0,         "IDX",   "STRUCT","Set light")
GPU(245, "DGETLIGHT",     2,    0.6,    0,         "STRUCT","IDX",   "Get light")
GPU(246, "DWRITEFMT",     2,    0.6,    0,         "VEC2F", "STRING","Write a formatted string")
GPU(247, "DWRITEFIX",     2,    0.5,    0,         "VEC2F", "Y",     "Write a fixed value")
GPU(248, "DTEXTWIDTH",    2,    0.8,    0,         "INT",   "STRING","Return text width")
GPU(249, "DTEXTHEIGHT",   2,    0.8,    0,         "INT",   "STRING","Return text height")
---- Dec 25 -- Vector mode extension ------------------------------------------------------------------------------------------------------------
VEX(250, "VADD",          2,   7.00,    0,         "VEC",   "VEC",   "X = X + Y")
VEX(251, "VSUB",          2,   7.00,    0,         "VEC",   "VEC",   "X = X - Y")
VEX(252, "VMUL",          2,   7.00,    0,         "VEC",   "X",     "X = X * SCALAR Y")
VEX(253, "VDOT",          2,   7.00,    0,         "VEC",   "VEC",   "X = X dot Y")
VEX(254, "VCROSS",        2,   7.00,    0,         "VEC",   "VEC",   "X = X cross Y")
VEX(255, "VMOV",          2,   7.00,    0,         "VEC",   "VEC",   "X = Y")
VEX(256, "VNORM",         2,   7.00,    0,         "VEC",   "VEC",   "X = NORMALIZE(Y)")
VEX(257, "VCOLORNORM",    2,   10.0,    0,         "COLOR", "COLOR", "Normalize color (clamp it to RGB range)")
GPU(258, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(259, "DLOOPXY",       2,    0.7,    CB,        "PTR",   "PTR",   "2D loop by ECX/EDX registers")
VEX(259, "LOOPXY",        2,   10.0,    CB,        "PTR",   "PTR",   "2D loop by ECX/EDX registers")
---- Dec 26 -- Matrix math ----------------------------------------------------------------------------------------------------------------------
VEX(260, "MADD",          2,   7.00,    0,         "MATRIX","MATRIX","X = X + Y")
VEX(261, "MSUB",          2,   7.00,    0,         "MATRIX","MATRIX","X = X - Y")
VEX(262, "MMUL",          2,   7.00,    0,         "MATRIX","MATRIX","X = X * Y")
VEX(263, "MROTATE",       2,   7.00,    0,         "MATRIX","VEC4F", "Rotation matrix based on rotation vector")
VEX(264, "MSCALE",        2,   7.00,    0,         "MATRIX","VEC4F", "Scaling matrix based on scaling vector")
VEX(265, "MPERSPECTIVE",  2,   7.00,    0,         "MATRIX","VEC4F", "Perspective matrix based on FOV and near/far planes")
VEX(266, "MTRANSLATE",    2,   7.00,    0,         "MATRIX","VEC4F", "Translation matrix based on translation vector")
VEX(267, "MLOOKAT",       2,   7.00,    0,         "MATRIX","VEC4F", "Lookat matrix based on three vectors")
VEX(268, "MMOV",          2,   7.00,    0,         "MATRIX","MATRIX","X = Y")
VEX(269, "VLEN",          2,   7.00,    0,         "X",     "VEC",   "X = Sqrt(Y dot Y)")
---- Dec 27 -- Matrix math ----------------------------------------------------------------------------------------------------------------------
VEX(270, "MIDENT",        1,   7.00,    0,         "MATRIX","",      "Load identity matrix")
GPU(271, "MLOADPROJ",     1,    0.6,    0,         "MATRIX","",      "Load matrix into view matrix")
GPU(272, "MREAD",         1,    0.6,    0,         "MATRIX","",      "Write view matrix into matrix")
VEX(273, "VMODE",         1,   7.00,    0,         "IDX",   "",      "Set vector math mode")
GPU(274, "DT",            1,    0.6,    W1,        "X",     "",      "Set X to frame length time")
GPU(275, "RESERVED",      1,    0.0,    0,         "",      "",      "")
GPU(276, "DSHADE",        1,    0.5,    0,         "X",     "",      "Shade the current color")
GPU(277, "DSETWIDTH",     1,    0.5,    0,         "X",     "",      "Set line width")
GPU(278, "MLOAD",         1,    0.6,    0,         "MATRIX","",      "Load matrix into model matrix")
GPU(279, "DSHADENORM",    1,    0.6,    0,         "X",     "",      "Shade the current color and normalize it")
GPU(279, "DSHADECOL",     1,    0.6,    OL,        "X",     "",      "DSHADENORM")
---- Dec 28 -- Advanced rendering ---------------------------------------------------------------------------------------------------------------
GPU(280, "DDFRAME",       1,    1.0,    0,         "STRUCT","",      "Draw bordered frame")
GPU(281, "DDBAR",         1,    1.0,    0,         "STRUCT","",      "Draw a progress bar")
GPU(282, "DDGAUGE",       1,    1.0,    0,         "STRUCT","",      "Draw gauge needle")
GPU(283, "DRASTER",       1,    0.6,    0,         "INT",   "",      "Set rasterizer quality level")
GPU(284, "DDTERRAIN",     1,    0.8,    0,         "STRUCT","",      "Draw terrain")
GPU(285, "RESERVED",      1,    0.0,    0,         "",      "",      "")
GPU(286, "RESERVED",      1,    0.0,    0,         "",      "",      "")
GPU(287, "RESERVED",      1,    0.0,    0,         "",      "",      "")
GPU(288, "RESERVED",      1,    0.0,    0,         "",      "",      "")
GPU(289, "RESERVED",      1,    0.0,    0,         "",      "",      "")
---- Dec 29 -- Additional instructions ----------------------------------------------------------------------------------------------------------
GPU(290, "DLOADBYTES",    2,    1.0,    0,         "IDX",   "PTR",   "Load into texture slot by pointer")
GPU(291, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(292, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(293, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(294, "DMULDT",        2,    0.7,    0,         "X",     "Y",     "X = Y * dT")
VEX(295, "VDIV",          2,   7.00,    0,         "VEC",   "Y",     "VEC = VEC / Y")
VEX(296, "VTRANSFORM",    2,   8.00,    0,         "VEC",   "MATRIX","X = X * MATRIX")
GPU(297, "DSMOOTH",       2,    1.0,    0,         "X",     "Y",     "Smooth X with smoothness Y")
GPU(298, "DBEGIN",        0,    1.0,    0,         "",      "",      "Begin rendering (from async thread)")
GPU(299, "DEND",          0,    1.0,    0,         "",      "",      "End rendering (from async thread)")
---- Dec 30 -- 3D rendering ---------------------------------------------------------------------------------------------------------------------
GPU(300, "DROTATE",       1,    1.0,    0,         "VEC4F", "",      "Rotate model by vector")
GPU(301, "DTRANSLATE",    1,    1.0,    0,         "VEC4F", "",      "Translate model by vector")
GPU(302, "DSCALE",        1,    1.0,    0,         "VEC4F", "",      "Scale model by vector")
GPU(303, "DXTEXTURE",     1,    1.0,    0,         "STR",   "",      "Bind a specific external texture")
GPU(304, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(305, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(306, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(307, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(308, "RESERVED",      2,    0.0,    0,         "",      "",      "")
GPU(309, "RESERVED",      2,    0.0,    0,         "",      "",      "")
---- Dec 31 -- UNDEFINED ------------------------------------------------------------------------------------------------------------------------
---- Dec 32 -- SPU output control ---------------------------------------------------------------------------------------------------------------
SPU(320, "CHRESET" ,      1,    1.0,    0,         "CHAN",  "",      "Reset channel")
SPU(321, "CHSTART",       1,    1.0,    0,         "CHAN",  "",      "Start sound on channel")
SPU(322, "CHSTOP",        1,    1.0,    0,         "CHAN",  "",      "Stop sound on channel")
SPU(323, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(324, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(325, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(326, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(327, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(328, "RESERVED",      1,    0.0,    0,         "",      "",      "")
SPU(329, "RESERVED",      1,    0.0,    0,         "",      "",      "")
---- Dec 33 -- SPU channel control --------------------------------------------------------------------------------------------------------------
SPU(330, "WSET",          2,    1.0,    0,         "WAVE",  "STRING","Set lookup name for specific wave")
SPU(331, "CHWAVE",        2,    1.0,    0,         "CHAN",  "WAVE",  "Set waveform")
SPU(332, "CHLOOP",        2,    1.0,    0,         "CHAN",  "IDX",   "Set looping mode")
SPU(333, "CHVOLUME",      2,    1.0,    0,         "CHAN",  "X",     "Set volume")
SPU(334, "CHPITCH",       2,    1.0,    0,         "CHAN",  "X",     "Set pitch (value interpretation depends on register)")
SPU(335, "CHMODT",        2,    1.0,    0,         "CHAN",  "X",     "Set LFO modulation type")
SPU(336, "CHMODA",        2,    1.0,    0,         "CHAN",  "X",     "Set LFO modulation amplitude")
SPU(337, "CHMODF",        2,    1.0,    0,         "CHAN",  "X",     "Set LFO modulation frequency")
SPU(338, "CHADSR",        2,    1.0,    0,         "CHAN",  "VEC4F", "Set channel ADSR")
SPU(339, "WLEN",          2,    1.0,    0,         "X",     "WAVE",  "Read sound length in seconds")
