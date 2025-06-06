--!strict

--[[
	
	---------------
	-- Lunimator --
	---------------
	
	Roblox Animator instance re-implementation.
	By JavierR100

--]]

local Luanimator = {}

-- SERVICES --

local TS = game:GetService("TweenService")

-- MODULES --

local BTween = require("@self/BTween") -- ew.

-- TYPING --

export type Luanimator = {
	LoadedTracks : {[string]:LuaTrack};
	Motors : {Motor6D};
	MotorC0 : {[Motor6D] : CFrame}; -- original values
	MotorC1 : {[Motor6D] : CFrame};
	PlayingTracks : {LuaTrack};

	LoadAnimation : (self:Luanimator, AnimData: KeySeqData)->LuaTrack;
	Update : (self:Luanimator, dt: number)->()
}

export type LuaTrack = {
	-- PUBLIC
	Speed: number;
	TimePosition: number;
	Priority: |Enum.AnimationPriority;
	Loop: boolean;

	FadeEndingTime: number; -- (+) fadeTime applied when the animation is done playing

	Play:(self:LuaTrack,fadeTime:number?,weight:number?,speed:number?)->();
	Stop:(self:LuaTrack,fadeTime:number?)->();
	AdjustWeight:(self:LuaTrack, new:number?, time:number?)->();
	AdjustSpeed:(self:LuaTrack, new:number?)->(); -- pro tip: writing .Speed directly also works!
	GetMarkerReachedSignal:(self:LuaTrack,name:string)->RBXScriptSignal;

	-- PROTECTED 
	CurrentWeight: number;
	TargetWeight: number;
	TimeLength: number;
	Playing: boolean;

	-- PRIVATE
	Data: any;
	PoseIndexes: {[Motor6D] : number};
	PoseLists: {[Motor6D] : {KeyPose}}; -- sorted
	Marks: {KeyframeMark};
	MarkerReachedSignals: {[string] : BindableEvent};
	MarkIndex: number;

	FiredLastMarker: boolean;
	WeightTween: BTween.BTween;
	FadeLength: number;

	-- EVENTS

	Stopped:RBXScriptSignal; -->()
	PrematureStopped:RBXScriptSignal; -->()    -- (+) For compatibility sake, i'm not including this on Stopped event
	Ended:RBXScriptSignal; -->()
	KeyframeReached:RBXScriptSignal; -->(name)
	_Events:{[string]:BindableEvent};
}

-- LOCAL TYPING --

type PoseData = {
	Weight: number;
	CFrame: CFrame;
	PartName: string;
	EasingStyle: |Enum.EasingStyle|Enum.PoseEasingStyle;
	EasingDirection: |Enum.EasingDirection|Enum.PoseEasingDirection;
	Subposes: {PoseData};
}

type MarkerData = {
	Name: string;
	Value: string;
}

type KeyframeData = {
	Name: string;
	Time: number;
	Poses: {PoseData};
	Markers: {MarkerData}?;
}

type KeySeqData = {
	Keyframes: {KeyframeData};
	Loop: boolean;
	Name: string;
	Priority: |Enum.AnimationPriority;
}

-- internal things

type KeyPose = {
	Time: number;
	Weight: number;
	CFrame: CFrame;
	EasingStyle: |Enum.EasingStyle|Enum.PoseEasingStyle;
	EasingDirection: |Enum.EasingDirection;
}

type WeightCalc = {
	Final: CFrame;
	Counter: number;
	Weight: number;
}

type KeyframeMark = {
	Name: string;
	Time: number;
	Value: string?; -- If this value is nil, then it's a Keyframe with a name.
}

-- Helper functions --

--[[ Parses a Pose instance and stores it on poseList.
	<strong>rootPose</strong>: Pose instance to recursively parse.
	<strong>poseList</strong>: Dictionary containing KeyPoses for each Motor6D.
	<strong>motorList</strong>: Motor6Ds to parse for.
	<strong>time</strong>: Length of the Animation. (Passed value for Time property in KeyPoses)
]]
local function parsePose(rootPose:PoseData,poseList:{[Motor6D] : {KeyPose}},motorList:{Motor6D},time:number)
	for _,Pose in next,rootPose.Subposes do

		-- find which motor matches
		local targetMotor
		for _,motor in next,motorList do
			if motor.Part0 and motor.Part1 and motor.Part0.Name == rootPose.PartName and motor.Part1.Name == Pose.PartName then
				targetMotor = motor
				break
			end
		end

		if targetMotor then
			local list = poseList[targetMotor]
			if list == nil then
				list = {}
				poseList[targetMotor] = list
			end
			if Pose.Weight > 0 then -- avoid including poses with 0 weight
				local ease: Enum.EasingDirection
				if Pose.EasingDirection.EnumType == Enum.PoseEasingDirection then
					ease = Enum.EasingDirection[Pose.EasingDirection.Name]
				else
					ease = Pose.EasingDirection :: Enum.EasingDirection
				end
				table.insert(list,{
					Time = time;
					Weight = Pose.Weight;
					CFrame = Pose.CFrame;
					EasingDirection = ease;
					EasingStyle = Pose.EasingStyle;
				})
			end
			parsePose(Pose,poseList,motorList,time)
		end


	end
end

-- Sorter function for tables with "Time" index.
local function sortByTime(a:any,b:any): boolean
	return a.Time < b.Time
end

-- given a circular range of 'length', return the shortest distance from 2 given points
local function getShortestDistance(a:number,b:number,length:number): number
	local ld = (a - b)%length
	local rd = (b - a)%length
	--return math.min(ld, rd)
	if ld < rd then
		return -ld
	else
		return rd
	end
end

-- point A to point B

-- given a circular range of 'length', return the sign for the shortest distance from 2 given points
local function getSignByDistance(a:number,b:number,length:number): number
	local ld = (a - b)%length
	local rd = (b - a)%length
	if ld < rd then
		return -1
	else
		return 1
	end
end

-- gets the next index number in a circular range of a specified length, assuming it's a 1-based array
local function getNextIndex1Based(index: number, length: number, direction: number): number
	--local direction = math.sign(direction)
	return (index - 1 + direction)%length + 1
end

--                            --
-- CLASS "LuaTrack" FUNCTIONS --
--                            --

function luaTrack_AdjustSpeed(self:LuaTrack,new:number?)
	self.Speed = new or 1
end

function luaTrack_AdjustWeight(self:LuaTrack,new:number?,fadeTime:number?)
	self.FadeLength = fadeTime or 0.100000001
	self.TargetWeight = new or 1

	if self.FadeLength > 0 then
		self.WeightTween.TweenInfo = TweenInfo.new(
			self.FadeLength,Enum.EasingStyle.Linear
		)
		self.WeightTween.EndValues.CurrentWeight = self.TargetWeight
		self.WeightTween:Recalculate()
		self.WeightTween:Play()
	else
		self.CurrentWeight = self.TargetWeight
	end
end

function luaTrack_GetMarkerReachedSignal(self:LuaTrack,name:string) : RBXScriptSignal
	local event = self.MarkerReachedSignals[name]
	if event == nil then
		event = Instance.new("BindableEvent")
		self.MarkerReachedSignals[name] = event
	end
	return event.Event
end


function luaTrack_Stop(self:LuaTrack,fadeTime:number?)
	if not self.Playing then
		return
	end
	self.Playing = false
	self.FadeLength = fadeTime or 0.100000001
	self._Events.PrematureStopped:Fire()

	self.TargetWeight = 0
	if self.FadeLength > 0 then
		self.WeightTween.TweenInfo = TweenInfo.new(
			self.FadeLength,Enum.EasingStyle.Linear
		)
		self.WeightTween.EndValues.CurrentWeight = self.TargetWeight
		self.WeightTween:Recalculate()
		self.WeightTween:Play()
	else
		self.CurrentWeight = self.TargetWeight
	end
end

--                              --
-- CLASS "Luanimator" FUNCTIONS --
--                              --

--[[
	Updates the humanoid joints and internal variables.
	<strong>self</strong>: The Luanimator to update.
	<strong>delta</strong>: Elapsed time.
]]--
local function luanimator_Update(self:Luanimator, delta:number)
	local prioritylist: {[Motor6D] : {WeightCalc}} = {}

	local i = 1
	-- iterate thru the playing LuaTracks
	while self.PlayingTracks[i] do
		local track = self.PlayingTracks[i]

		if (not track.Playing) and not track.WeightTween.Playing then
			table.remove(self.PlayingTracks,i)
			continue
		end

		local step = 0
		local lastTimePos = track.TimePosition
		if track.Playing then
			step = delta*track.Speed
			track.TimePosition += step	
			if track.Loop then
				track.TimePosition %= track.TimeLength
			end
		end

		--
		if #track.Marks > 0 then -- iterate thru marks, if there's 1 or more
			local stepSign = math.sign(step)
			local markIndex = track.MarkIndex

			local nextMark = track.Marks[markIndex]

			local mustUpdateMarkers = if track.Loop then true else not track.FiredLastMarker
			if stepSign < 0 then

				mustUpdateMarkers = mustUpdateMarkers and nextMark.Time > track.TimePosition 
			else
				mustUpdateMarkers = mustUpdateMarkers and track.TimePosition > nextMark.Time
			end


			if mustUpdateMarkers then
				if stepSign == 0 then
					stepSign = 1
				end

				repeat

					local deltaTime
					if track.Loop then
						deltaTime = (nextMark.Time - lastTimePos)%track.TimeLength * stepSign
					else
						deltaTime = (nextMark.Time - lastTimePos) * stepSign
					end

					if deltaTime > math.abs(step) then
						track.MarkIndex = markIndex
						break

					elseif deltaTime < 0 then
						-- do not fire at all
						track.FiredLastMarker = (not track.Loop) and (step < 0 and markIndex == 1 or markIndex == #track.Marks)

					elseif math.abs(step) > deltaTime then
						if nextMark.Value then
							local signal = track.MarkerReachedSignals[nextMark.Name]
							if signal then
								signal:Fire(nextMark.Value)
							end
						else
							track._Events.KeyframeReached:Fire(nextMark.Name)
						end

						track.FiredLastMarker = (not track.Loop) and (step < 0 and markIndex == 1 or markIndex == #track.Marks)
					end


					if track.Loop then
						markIndex = getNextIndex1Based(markIndex,#track.Marks,stepSign)
					else
						markIndex += stepSign
					end

					nextMark = track.Marks[markIndex]

				until not nextMark
			end
			-- this was an absolute nightmare to get working, i wouldn't be surprised if there are unchecked bugs here...
		end

		-- then iterate thru every KeyPose to determine the CFrame transform
		for motor, keyposeList in next,track.PoseLists do
			local priority = track.Priority.Value
			if priority == 1000 then -- "lowest" my ass
				priority = 0
			else
				priority += 1
			end


			local nowIndex = track.PoseIndexes[motor] or 1
			local step = math.sign(step)

			local blendCFrame = CFrame.identity

			local currKeyPose = keyposeList[nowIndex] 
			local nextKeyPose : KeyPose? = keyposeList[nowIndex+1]

			-- find the new nowIndex if TimePosition is out of range between the 2 KeyPose's times
			if
				(nextKeyPose and track.TimePosition > nextKeyPose.Time)
				or (track.TimePosition < currKeyPose.Time and keyposeList[nowIndex-1])
			then
				if step == 0 or (step > 0 and track.TimePosition < currKeyPose.Time) or (step < 0 and track.TimePosition > currKeyPose.Time) then
					step = getSignByDistance(track.TimePosition,currKeyPose.Time,track.TimeLength)
				end

				repeat
					-- go to next index step
					if track.Loop then
						nowIndex = getNextIndex1Based(nowIndex,#keyposeList,step) -- 1-based array compliant indexing modulo
					else
						nowIndex = math.clamp(nowIndex + step,0,#keyposeList) -- including out of bounds keyposes
					end

					currKeyPose = keyposeList[nowIndex]
					nextKeyPose = keyposeList[nowIndex+1]

					if 
						nextKeyPose and currKeyPose
						and track.TimePosition <= nextKeyPose.Time and track.TimePosition >= currKeyPose.Time
					then
						-- TimePosition is currently between 2 keyposes, stop looping
						break

					end
				until not (currKeyPose and nextKeyPose) -- one keypose is not available, intended for non-looped animations
				track.PoseIndexes[motor] = nowIndex
			end

			-- calculate the Transform CFrame
			if nextKeyPose and currKeyPose then
				-- both keys exist, so just interpolate them both
				local alpha
				if currKeyPose.EasingStyle.EnumType == Enum.PoseEasingStyle then
					-- this enum in specific sucks
					if currKeyPose.EasingStyle == Enum.PoseEasingStyle.Constant then
						-- snapping anim
						if currKeyPose.EasingDirection == Enum.EasingDirection.In then
							alpha = 0
						elseif currKeyPose.EasingDirection == Enum.EasingDirection.Out then
							alpha = 1
						else
							alpha = math.round(alpha)
						end
					elseif -- is there any real difference between these two?
						currKeyPose.EasingStyle == Enum.PoseEasingStyle.Cubic
						or currKeyPose.EasingStyle == Enum.PoseEasingStyle.CubicV2
					then
						alpha = TS:GetValue(
							(track.TimePosition-currKeyPose.Time)/(nextKeyPose.Time-currKeyPose.Time),
							Enum.EasingStyle.Cubic,
							currKeyPose.EasingDirection
						)
					elseif currKeyPose.EasingStyle == Enum.PoseEasingStyle.Linear then
						alpha = (track.TimePosition-currKeyPose.Time)/(nextKeyPose.Time-currKeyPose.Time)
					elseif currKeyPose.EasingStyle == Enum.PoseEasingStyle.Bounce then
						alpha = TS:GetValue(
							(track.TimePosition-currKeyPose.Time)/(nextKeyPose.Time-currKeyPose.Time),
							Enum.EasingStyle.Bounce,
							currKeyPose.EasingDirection
						)
					elseif currKeyPose.EasingStyle == Enum.PoseEasingStyle.Elastic then
						alpha = TS:GetValue(
							(track.TimePosition-currKeyPose.Time)/(nextKeyPose.Time-currKeyPose.Time),
							Enum.EasingStyle.Elastic,
							currKeyPose.EasingDirection
						)
					end
				else
					-- the real deal
					alpha = TS:GetValue(
						(track.TimePosition-currKeyPose.Time)/(nextKeyPose.Time-currKeyPose.Time),
						currKeyPose.EasingStyle,
						currKeyPose.EasingDirection
					)
				end
				blendCFrame = currKeyPose.CFrame:Lerp(nextKeyPose.CFrame,alpha)
			elseif (nextKeyPose or currKeyPose) then
				-- freeze the pose on the singular keypose
				local singleKeyPose = nextKeyPose or currKeyPose
				blendCFrame = singleKeyPose.CFrame
			end

			-- then assign the resulting CFrame into the priority CFrame list
			local indexedPriorityList = prioritylist[motor]
			if indexedPriorityList == nil then
				indexedPriorityList = {}
				prioritylist[motor] = indexedPriorityList
			end
			local wc = indexedPriorityList[priority] 
			if wc then
				wc.Counter += 1;
				wc.Weight += track.CurrentWeight
				wc.Final = wc.Final:Lerp(blendCFrame,track.CurrentWeight/wc.Weight)
			else
				wc = {
					Counter = 1; 
					Final = blendCFrame;
					Weight = track.CurrentWeight;
				}
				indexedPriorityList[priority] = wc
			end

		end

		if track.Playing and (track.TimePosition > track.TimeLength or track.TimePosition < 0) then
			-- animation has ended
			local overTime = 0
			if track.TimePosition > track.TimeLength then
				overTime = (track.TimePosition-track.TimeLength)
			elseif track.TimePosition < 0 then
				overTime = -track.TimePosition
				-- is this faster than math.abs??
			end
			track.Playing = false
			track.FadeLength = track.FadeEndingTime
			track._Events.Stopped:Fire()
			if track.WeightTween.Playing and track.WeightTween.EndValues.TargetWeight ~= 0 then
				track.WeightTween:Cancel()
			end
			if track.FadeLength > 0 and not track.WeightTween.Playing then
				track.WeightTween.TweenInfo = TweenInfo.new(
					track.FadeLength,Enum.EasingStyle.Linear
				)
				track.WeightTween.EndValues.CurrentWeight = 0
				track.WeightTween:Recalculate()
				track.WeightTween:Play(overTime)
			end
		end

		track.WeightTween:Update(delta)
		i += 1
	end

	for motor, wcl in next,prioritylist do
		local trueFinal = CFrame.identity
		local avg
		for priority,wc in next,wcl do
			avg = wc.Weight/wc.Counter
			--print(`{priority} > {wc.Weight} *{wc.Counter} ({avg})`)
			if avg == 0 then
				continue
			end
			-- contender for micro-optimization: do this iteration in reverse just to skip lower prioritized animations
			if avg >= 1 then
				trueFinal = wc.Final
			else
				trueFinal = trueFinal:Lerp(wc.Final,math.clamp(avg,0,1))
			end

		end
		-- result offset: C0 * C1:Inverse() * Transform
		motor.C0 = self.MotorC0[motor] * trueFinal
	end
end

--[[
	Loads an animation, returns a LuaTrack instance.
	<strong>self</strong>: The Luanimator to load.
	<strong>data</strong>: Parsed animation table data to load.
]]--
local function luanimator_LoadAnimation(self:Luanimator, data: KeySeqData) : LuaTrack
	local stoppedSignal = Instance.new("BindableEvent")
	local endedSignal = Instance.new("BindableEvent")
	local reachedSignal = Instance.new("BindableEvent")
	local prematureSignal = Instance.new("BindableEvent")
	local track:LuaTrack = {
		PoseLists = {};
		Speed = 1;
		Playing = false;
		FadeLength = 0;
		TimePosition = 0;
		TimeLength = 0;
		Loop = data.Loop;

		CurrentWeight = 0;
		TargetWeight = 0;
		WeightTween = BTween.Create(string,TweenInfo.new(),{});
		MarkIndex = 1;
		FiredLastMarker = false;

		FadeEndingTime = 0.100000001;

		MarkerReachedSignals = setmetatable({},{__mode = "v"}) :: any;
		Marks = {};
		PoseIndexes = {};
		Priority = data.Priority;
		Play = function(this,fadeTime,weight,speed)

			if this.Playing then
				return
			end

			if not table.find(self.PlayingTracks,this) then
				table.insert(self.PlayingTracks,this)
			end

			this.TimePosition = 0
			for motor,index in next, this.PoseIndexes do
				this.PoseIndexes[motor] = 1
			end
			this.MarkIndex = 1
			this.Speed = speed or 1
			this.FadeLength = fadeTime or 0.100000001
			this.Playing = true
			this.FiredLastMarker = false

			this.TargetWeight = weight or 1
			if this.WeightTween.Playing then
				this.WeightTween:Cancel()
			end
			if this.FadeLength > 0 then
				this.WeightTween.TweenInfo = TweenInfo.new(
					this.FadeLength,Enum.EasingStyle.Linear
				)
				this.WeightTween.EndValues.CurrentWeight = this.TargetWeight
				this.WeightTween:Recalculate()
				this.WeightTween:Play()
			else
				this.CurrentWeight = this.TargetWeight
			end
		end,
		Stop = luaTrack_Stop;
		AdjustWeight = luaTrack_AdjustWeight;
		AdjustSpeed = luaTrack_AdjustSpeed;
		GetMarkerReachedSignal = luaTrack_GetMarkerReachedSignal;
		Stopped = stoppedSignal.Event;
		PrematureStopped = prematureSignal.Event;
		Ended = endedSignal.Event;
		KeyframeReached = reachedSignal.Event;
		_Events = {
			Stopped = stoppedSignal;
			PrematureStopped = prematureSignal;
			Ended = endedSignal;
			KeyframeReached = reachedSignal;
		}
	}
	track.WeightTween.Target = track
	track.WeightTween.InitValues.CurrentWeight = 0
	track.WeightTween.EndValues.CurrentWeight = 1
	track.WeightTween.UseLerpList.CurrentWeight = false

	for _,Keyframe in next,data.Keyframes do
		for _,rootPose in next,Keyframe.Poses do
			parsePose(rootPose,track.PoseLists,self.Motors,Keyframe.Time)
		end
		if Keyframe.Markers then
			for _,marker in next,Keyframe.Markers do
				local mark:KeyframeMark = {
					Name = marker.Name;
					Time = Keyframe.Time;
					Value = marker.Value;
				}
				table.insert(track.Marks,mark)
			end
		end

		if Keyframe.Name ~= "Keyframe" then
			local mark:KeyframeMark = {
				Name = Keyframe.Name;
				Time = Keyframe.Time;
			}
			table.insert(track.Marks,mark)
		end
	end
	table.sort(track.Marks,sortByTime)
	for motor,poseList in next,track.PoseLists do
		table.sort(poseList,sortByTime)
		if poseList[#poseList].Time > track.TimeLength then
			track.TimeLength = poseList[#poseList].Time
		end
	end

	self.LoadedTracks[data.Name] = track 
	return track
end

---------------
-- SINGLETON --
---------------

-- Sets up a Luanimator instance.
-- <strong>character</strong>: A humanoid character model.
function Luanimator.new(character:Model): Luanimator
	local hum = character:FindFirstChildOfClass("Humanoid") 
	assert(hum,"Missing humanoid")
	assert(hum.RootPart,"Missing HumanoidRootPart")

	local this: Luanimator = {
		LoadedTracks = {};
		Motors = {};
		MotorC0 = {};
		MotorC1 = {};
		PlayingTracks = {};

		LoadAnimation = luanimator_LoadAnimation;
		Update = luanimator_Update;
	}

	for i,v in next,character:GetDescendants() do
		if v:IsA("Motor6D") and v.Enabled then
			table.insert(this.Motors,v)
			this.MotorC0[v] = v.C0
			this.MotorC1[v] = v.C1
		end
	end

	return this
end

-- PARSER --

-- Recursively parses Pose data
function parseKeyframeSeqPose(pose: Pose)
	local subList = {}
	local data = {
		PartName = pose.Name;
		CFrame = pose.CFrame;
		Weight = pose.Weight;
		EasingDirection = pose.EasingDirection;
		EasingStyle = pose.EasingStyle;

		Subposes = subList;
	}

	for _,subpose in next,pose:GetChildren() do
		if subpose:IsA("Pose") then
			table.insert(subList,parseKeyframeSeqPose(subpose))
			-- should include NumberPose?
		end
	end	

	return data
end

-- Parses a KeyframeSequence container into a Lua table
function Luanimator.parseKeyframeSequence(seq: KeyframeSequence): KeySeqData
	local output: KeySeqData = {
		Name = seq.Name;
		Loop = seq.Loop;
		Priority = seq.Priority;

		Keyframes = {};
	}

	for _,child in next,seq:GetChildren() do
		if child:IsA("Keyframe") then
			local kfdata: KeyframeData = {
				Name = child.Name;
				Time = child.Time;
				Poses = {};
			}
			table.insert(output.Keyframes,kfdata)

			for _,pose in next,child:GetChildren() do
				if pose:IsA("Pose") then
					table.insert(kfdata.Poses,parseKeyframeSeqPose(pose))
				elseif pose:IsA("KeyframeMarker") then
					if kfdata.Markers == nil then
						kfdata.Markers = {}
					end
					assert(kfdata.Markers,"Screw luau linting :(")
					table.insert(kfdata.Markers,{
						Name = pose.Name;
						Value = pose.Value;
					})
				end
			end
		end
	end

	return output
end

return Luanimator