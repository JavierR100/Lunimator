--!strict
--!optimize 2

-- Unlike TweenService:Create(), this uses Benchmarking to update the tweening.
-- Not only that, but allows the usage of tweening to Tables and Userdatas (Instances too)
-- Even accepting Table as values (assuming they have metatables) for math operations/lerping!

-- NOT THE ORIGINAL MODULE, THIS IS MODIFIED SPECIFICALLY FOR LUNIMATOR

local TwS = game:GetService("TweenService")
local RS = game:GetService("RunService")

local Creator = {}

export type BTween = {
	Target:any; -- we're dealing with userdatas/tables here!
	Playing:boolean;
	TimePosition:number;
	TimeLength:number; -- basically the time point returned by os.clock, which helps defining TimePosition.
	TweenInfo:TweenInfo; -- repeatCount and reverses are ignored.
	Speed:number;

	UseLerpList:{[string]:boolean}; -- Beacuse certain Userdatas don't allow * operations, they sometimes will have the :Lerp() method!
	InitValues:{[string]:any};
	EndValues:{[string]:any};
	DiffValues:{[string]:any};
	-- functions
	Update:(self:BTween, dt:number)->();
	Play:(self:BTween,time:number?,ignoreDelay:boolean?)->();
	Cancel:(self:BTween,resetTarget:boolean?)->();
	Recalculate:(self:BTween)->();
	RecalculateValues:(self:BTween)->();
	-- callbacks
	OnComplete:(self:BTween)->()?;
}

-- HELPER FUNCTIONS

local function get(t:any,i:any) return t[i] end

-- FUNCTIONS

-- Updates the BetterTween instance.
local function Class_Update(self:BTween, dt:number)
	if not self.Playing then return end

	local timeElapsed = self.TimePosition + dt --(os.clock() - self.ClockStart) * self.Speed
	local alpha = timeElapsed/self.TweenInfo.Time
	if alpha ~= alpha then -- nan detection
		alpha = 1
	end
	local tweenedAlpha = TwS:GetValue(alpha,self.TweenInfo.EasingStyle,self.TweenInfo.EasingDirection)

	if alpha >= 1 then
		self.Playing = false
		for property,mustLerp in next,self.UseLerpList do
			self.Target[property] = self.EndValues[property]
		end
		if self.OnComplete then
			self.OnComplete(self)
		end
		-- stop playing once it reached the final, while setting the value to the end too..
	elseif alpha < 0 then
		for property,mustLerp in next,self.UseLerpList do
			self.Target[property] = self.InitValues[property]
		end
		-- just set the property as the initial value, just to accept delaying.
	else
		for property,mustLerp in next,self.UseLerpList do
			if mustLerp then
				self.Target[property] = self.InitValues[property]:Lerp(self.EndValues[property],tweenedAlpha)
			else
				self.Target[property] = self.InitValues[property] + self.DiffValues[property]*tweenedAlpha
			end
		end
	end
	self.TimePosition = timeElapsed
end

-- Starts the tweening.
-- <strong>time</strong>: Time position to start from.
-- <strong>ignoreDelay</strong>: Whenever it shouldn't consider DelayTime as part of the tween.
local function Class_Play(self:BTween,time:number?,ignoreDelay:boolean?)
	local actualTime = time or 0
	assert(actualTime <= self.TweenInfo.DelayTime + self.TweenInfo.Time,"Time is out of bounds")

	self.Playing = true
	if ignoreDelay then
		--self.ClockStart = os.clock() - actualTime
		self.TimePosition = actualTime
	else
		--self.ClockStart = os.clock() + self.TweenInfo.DelayTime - actualTime
		self.TimePosition = actualTime - self.TweenInfo.DelayTime
	end
	self:Update(0)
end

-- Update the variables in order to reflect the new property values.
local function Class_Recalculate(self:BTween)
	for name,origValue in next,self.InitValues do
		local newValue:any? = select(2,pcall(get,self.Target,name))
		if newValue then
			self.InitValues[name] = newValue
			if not self.UseLerpList[name] then
				self.DiffValues[name] = self.EndValues[name] - newValue
			end
		else
			warn(`Unable to obtain {name} value from target`)
		end
	end
end

-- Update the variables with what's given already to the BetterTween.
local function Class_RecalculateValues(self:BTween)
	for name,origValue in next,self.InitValues do
		local newValue:any? = origValue
		if newValue then
			self.InitValues[name] = newValue
			if not self.UseLerpList[name] then
				self.DiffValues[name] = self.EndValues[name] - newValue
			end
		else
			warn(`Missing {name} EndValue property`)
		end
	end
end

-- Stops the Tween.
-- <strong>reset</strong>: Resets the tween variables to the original state if true.
local function Class_Cancel(self:BTween,reset:boolean?)
	if not self.Playing then return end
	self.Playing = false
	if reset then
		for name,origValue in next,self.InitValues do
			self.Target[name] = origValue
		end
	end
	--self.ClockStart = os.clock() - self.TweenInfo.Time
	self.TimePosition = 0
end

-- Updates an array of BetterTweens.
-- <strong>array</strong>: Array of BetterTween instances.
-- <strong>noRemoval</strong>: Prevent removing items from the array if they aren't playing if true.
function Creator.ManualUpdate(array:{BTween}, dt:number,noRemoval:boolean?) -- Lazy? Idk but i think it's performant this way..
	local i = 1
	while array[i] do 
		local tween = array[i]
		if tween.Playing then
			tween:Update(dt)
		elseif not noRemoval then
			table.remove(array,i)
			continue
		end
		i += 1
	end
end

function Creator.Create(target:any,TweenInfo:TweenInfo,values:{[string]:any}): BTween
	do local targetType = type(target) 
		if targetType ~= "table" and targetType ~= "userdata" then error(`The provided target cannot be tweened. (Got {typeof(target)})`) end
	end
	assert(typeof(TweenInfo) == "TweenInfo","Invalid TweenInfo")

	local starterValues,endValues,diffValues = {},{},{}
	local useLerpList = {}
	for name,value in next,values do
		-- is the value itself the same?
		local currValue:any? = select(2,pcall(get,target,name))
		if currValue == nil then
			warn(`{name} cannot be tweened, got nil`)
		end
		local sameType = typeof(value) == typeof(currValue)
		if not sameType then
			warn(`{name} cannot be tweened. {typeof(currValue)} Expected, got {typeof(value)}`)
			continue
		end
		assert(sameType)

		-- check if the value is supported for math operations or lerping
		local hasLerp = pcall(get,value,"Lerp")
		local canBeMul = pcall(function() return value*1 end)
		local canBeSub = pcall(function() return value-value end)
		local canBeAdd = pcall(function() return value+value end)

		if hasLerp or (canBeMul and canBeAdd and canBeSub) then
			useLerpList[name] = hasLerp
			starterValues[name] = currValue
			endValues[name] = value
			if not hasLerp then
				diffValues[name] = value - currValue
			end
		else
			warn(`{name} cannot be tweened, Got {typeof(value)}`)
		end
	end

	local this:BTween = {
		Playing = false;
		Target = target;
		Speed = 1;
		TweenInfo = TweenInfo;
		TimePosition = 0;
		TimeLength = 0;
		EndValues = endValues;
		InitValues = starterValues;
		DiffValues = diffValues;
		UseLerpList = useLerpList;
		Play = Class_Play;
		Update = Class_Update;
		Recalculate = Class_Recalculate;
		RecalculateValues = Class_RecalculateValues;
		Cancel = Class_Cancel;
	}
	return this
end

return Creator
