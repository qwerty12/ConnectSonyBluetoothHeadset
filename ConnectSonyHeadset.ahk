#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
; #Warn  ; Enable warnings to assist with detecting common errors.
;#NoTrayIcon
SetBatchLines -1
ListLines Off
AutoTrim Off
;SetWorkingDir %A_ScriptDir%  ; Ensures a consistent starting directory.
#SingleInstance Force
Process, Priority,, A

dev := "WH-1000XM3:"

doRelease := False
,justDisconnect := False
,skipReconnect := False
for n, param in A_Args
{
    if (param == "/disconnect")
		justDisconnect := True
	else if (param == "/skipreconnect")
		skipReconnect := True
}

connectedDevCount := 0
while ((device := VA_GetDevice(dev . A_Index))) {
	if (!skipReconnect)
		DisconnectHeadset(device)
	else
		skipReconnect := A_Index
	ObjRelease(device)
}

if (justDisconnect)
	ExitApp

if (!skipReconnect || !connectedDevCount)
{
	ChangeRadioState(3, 1, True, doRelease)
	Sleep 1000

	while ((device := FindAudDevice(dev . A_Index, False, True, doRelease))) {
		ConnectHeadset(device, False, doRelease)
		if (doRelease)
			ObjRelease(device)
	}
}

DisableNoiseCancelling()

ExitApp

;if (A_ScriptName = "RadioState
;any := -1, RadioKind_Other = 0, RadioKind_WiFi = 1, RadioKind_MobileBroadband = 2, RadioKind_Bluetooth = 3, RadioKind_FM = 4
;toggle := 0, RadioState_On = 1, RadioState_Off = 2
ChangeRadioState(radioKind, newState, wait := True, doRelease := True)
{
	ret := False

	if ((radioKind < -1 || radioKind > 4) || (newState < 0 || newState > 2))
		return ret

	; There's a far easier way than this, but it's undocumented
	if (!(instRadios := ActivateRtClass("Windows.Devices.Radios.Radio", "{5FB6A12E-67CB-46AE-AAE9-65919F86EFF4}"))) ;IRadioStatics
		return ret

	try {
		if (DllCall(NumGet(NumGet(instRadios+0)+9*A_PtrSize), "Ptr", instRadios, "Ptr*", asyncRadioOp) < 0) ;::RequestAccessAsync()
			return ret

		pRadioAsyncHldr := AsyncActionCompletedHandler_new(["{BD248E73-F05F-574C-AE3D-9B95C4BF282A}", "{D30691E6-60A0-59C9-8965-5BBE282E8208}"])

		if (WaitForResult(asyncRadioOp, result, "UInt*", pRadioAsyncHldr) != 1 || result != 1)
			return ret

		if (DllCall(NumGet(NumGet(instRadios+0)+6*A_PtrSize), "Ptr", instRadios, "Ptr*", asyncRadioOp) < 0) ;::GetRadiosAsync
			return ret

		if (WaitForResult(asyncRadioOp, radioVectorView,, pRadioAsyncHldr) != 1 || !radioVectorView)
			return ret

		if (DllCall(NumGet(NumGet(radioVectorView+0)+7*A_PtrSize), "Ptr", radioVectorView, "UInt*", i) < 0)
			return ret

		Loop % i {
			if (!DllCall(NumGet(NumGet(radioVectorView+0)+6*A_PtrSize), "Ptr", radioVectorView, "UInt", A_Index - 1, "Ptr*", radio)) {
				if ((radioKind == -1) || (!DllCall(NumGet(NumGet(radio+0)+11*A_PtrSize), "Ptr", radio, "UInt*", k) && k == radioKind)) {
					if (DllCall(NumGet(NumGet(radio+0)+9*A_PtrSize), "Ptr", radio, "UInt*", currState) < 0) {
						if (newState == 0) {
							if (doRelease)
								ObjRelease(radio)
							continue
						}
					}

					if (newState == 0) {
						state := currState == 1 ? 2 : 1
					} else {
						if (currState == newState)
							continue
						state := newState
					}

					ret := True
					if (!DllCall(NumGet(NumGet(radio+0)+6*A_PtrSize), "Ptr", radio, "UInt", state, "Ptr*", asyncRadioOp) && wait)
						WaitForResult(asyncRadioOp,, "UInt*", pRadioAsyncHldr)
				}
				if (doRelease)
					ObjRelease(radio)
			}
		}
	} finally {
		if (doRelease) {
			if (radioVectorView)
				ObjRelease(radioVectorView)

			if (pRadioAsyncHldr)
				ObjRelease(pRadioAsyncHldr)

			if (instRadios)
				ObjRelease(instRadios)
		}
	}
	
	return ret
}

; Here lies crap to implement the RT interop needed
WaitForResult(pASyncAction, ByRef result := 0, retType := "Ptr*", pAsyncCompletedHandler := 0, dwTimeoutMs := 0xFFFFFFFF)
{
	static IID_IAsyncInfo := "{00000036-0000-0000-C000-000000000046}"
	ret := 3 ;AsyncStatus::Error

	if (!pASyncAction)
		return ret

	try if AsyncInfo := ComObjQuery(pASyncAction, IID_IAsyncInfo) {
		if (DllCall(NumGet(NumGet(AsyncInfo+0)+7*A_PtrSize), "Ptr", AsyncInfo, "UInt*", ret) >= 0 && ret != 1) { ;.get_Status, AsyncStatus::Completed
			fallback_to_polling := !pAsyncCompletedHandler

			if (!fallback_to_polling) {
				if (DllCall(NumGet(NumGet(pASyncAction+0)+6*A_PtrSize), "Ptr", pASyncAction, "Ptr", pAsyncCompletedHandler) >= 0) { ;::put_Completed
					r := -1
					,hEvent := AsyncActionCompletedHandler_gethEvent(pAsyncCompletedHandler)
					,dwStart := A_TickCount
					while ((dwElapsed := A_TickCount - dwStart) < dwTimeoutMs) {
						if (dwTimeoutMs == 0xFFFFFFFF)
							dwElapsed := 0
						r := DllCall("MsgWaitForMultipleObjectsEx", "UInt", 1, "Ptr*", hEvent, "UInt", dwTimeoutMs - dwElapsed, "UInt", 0x4FF, "UInt", 0x6)
						Sleep -1
						if (r == 0 || r == -1 || r == 258)
							break
					}

					if (r == 0)
						ret := AsyncActionCompletedHandler_getResult(pAsyncCompletedHandler)
					else
						DllCall(NumGet(NumGet(AsyncInfo+0)+9*A_PtrSize), "Ptr", AsyncInfo) ;::Cancel
				} else {
					fallback_to_polling := True
				}
			}

			if (fallback_to_polling) {
				dwStart := A_TickCount
				Loop {
					Sleep 50

					if (DllCall(NumGet(NumGet(AsyncInfo+0)+7*A_PtrSize), "Ptr", AsyncInfo, "UInt*", ret) < 0 || ret > 0) ;.get_Status
						break

					if (dwTimeoutMs != 0xFFFFFFFF) {
						if (A_TickCount - dwStart > dwTimeoutMs) {
							DllCall(NumGet(NumGet(AsyncInfo+0)+9*A_PtrSize), "Ptr", AsyncInfo) ;::Cancel
							break
						}
					}
				}
			}
		}

		if (ret == 1 && IsByRef(result) && DllCall(NumGet(NumGet(pASyncAction+0)+8*A_PtrSize), "Ptr", pASyncAction, retType, result) < 0) ;.GetResults
			ret := 3

		DllCall(NumGet(NumGet(AsyncInfo+0)+10*A_PtrSize), "Ptr", AsyncInfo) ;::Close
		,ObjRelease(AsyncInfo)
	}

	ObjRelease(pASyncAction)
	return ret
}

ActivateRtClass(activatableClassId, szIid)
{
	static GUID
	if !VarSetCapacity(GUID)
		VarSetCapacity(GUID, 16)

	if (DllCall("ole32.dll\CLSIDFromString", "WStr", szIid, "Ptr", &GUID) < 0)
		return 0

	if (DllCall("combase.dll\RoGetActivationFactory", "Ptr", (_ := new HSTRING(activatableClassId))._, "Ptr", &GUID, "Ptr*", pObj) >= 0)
		return pObj

	return 0
}

AsyncActionCompletedHandler_new(arrszAsyncActionCompletedHandlerIIDs)
{
	; Apparently, each RT class has its own AsyncActionCompletedHandler IID...
	cIIDs := arrszAsyncActionCompletedHandlerIIDs.Count()
	if (!cIIDs)
		return 0

	VarSetCapacity(GUIDs, cIIDs * 16)
	for i, k in arrszAsyncActionCompletedHandlerIIDs
		if (DllCall("ole32.dll\CLSIDFromString", "WStr", k, "Ptr", &GUIDs+(16 * --i)) < 0)
			return 0

	; VTable, refcount, hEvent, result, cIIDs, IIDs
	handler := DllCall("GlobalAlloc", "UInt", 0x0000, "UPtr", A_PtrSize + 4 + A_PtrSize + 4 + 4 + VarSetCapacity(GUIDs), "Ptr")
	if (!handler)
		return 0

	NumPut(AsyncActionCompletedHandler_Vtbl(), handler+0,, "Ptr")
	,NumPut(1, handler+0, A_PtrSize, "UInt")
	,NumPut(DllCall("CreateEvent", "Ptr", 0, "Int", False, "Int", False, "Ptr", 0, "Ptr"), handler+0, A_PtrSize + 4, "Ptr")
	,NumPut(3, handler+0, A_PtrSize+4+A_PtrSize, "UInt")
	,NumPut(cIIDs, handler+0, A_PtrSize+4+A_PtrSize+4, "UInt")
	,DllCall("ntdll\RtlMoveMemory", "Ptr", handler+A_PtrSize+4+A_PtrSize+4+4, "Ptr", &GUIDs, "UPtr", VarSetCapacity(GUIDs))

	return handler
}

; handle not duplicated, so don't close it!
AsyncActionCompletedHandler_gethEvent(this_)
{
	return this_ ? NumGet(this_+0, A_PtrSize + 4, "Ptr") : 0
}

AsyncActionCompletedHandler_getResult(this_)
{
	return this_ ? NumGet(this_+0, A_PtrSize+4+A_PtrSize, "UInt") : 3
}

AsyncActionCompletedHandler_Invoke(this_, asyncAction, status)
{
	Critical
	NumPut(status, this_+0, A_PtrSize+4+A_PtrSize, "UInt")
	,DllCall("SetEvent", "Ptr", AsyncActionCompletedHandler_gethEvent(this_))
	Critical Off
	return 0
}

AsyncActionCompletedHandler_Vtbl()
{
	static vtable
	if (!VarSetCapacity(vtable)) {
		extfuncs := ["QueryInterface", "AddRef", "Release", "Invoke"]
		,VarSetCapacity(vtable, extfuncs.Length() * A_PtrSize)

		for i, name in extfuncs
			NumPut(RegisterCallback("AsyncActionCompletedHandler_" . name), vtable, (i-1) * A_PtrSize)
	}
	return &vtable
}

AsyncActionCompletedHandler_QueryInterface(this_, riid, ppvObject)
{
	static IID_IUnknown, IsEqualGUID := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", "ole32.dll", "Ptr"), "AStr", "IsEqualGUID", "Ptr")
	if (!VarSetCapacity(IID_IUnknown))
		VarSetCapacity(IID_IUnknown, 16)
		,DllCall("ole32\CLSIDFromString", "WStr", "{00000000-0000-0000-C000-000000000046}", "Ptr", &IID_IUnknown)

	match := False
	,off := this_+A_PtrSize+4+A_PtrSize+4+4
	Loop % NumGet(this_+0, A_PtrSize+4+A_PtrSize+4, "UInt") {
		if match := DllCall(IsEqualGUID, "Ptr", riid, "Ptr", off)
			break
		off += 16
	}

	if (!match)
		match := DllCall(IsEqualGUID, "Ptr", riid, "Ptr", &IID_IUnknown)

	if (match) {
		NumPut(this_, ppvObject+0, "Ptr")
		,AsyncActionCompletedHandler_AddRef(this_)
		return 0 ; S_OK
	}
	else {
		/*
		VarSetCapacity(buf, 78)
		,DllCall("ole32\StringFromGUID2", "Ptr", riid, "Ptr", &buf, "Int", 39)
		OutputDebug % StrGet(&buf, "UTF-16")
		*/

		NumPut(0, ppvObject+0, "Ptr")
		return 0x80004002 ; E_NOINTERFACE
	}
}

AsyncActionCompletedHandler_AddRef(this_)
{
	NumPut((_refCount := NumGet(this_+0, A_PtrSize, "UInt") + 1), this_+0, A_PtrSize, "UInt")
	return _refCount
}
 
AsyncActionCompletedHandler_Release(this_) {
	; thanks, just me
	_refCount := NumGet(this_+0, A_PtrSize, "UInt")
	if (_refCount > 0) {
		NumPut(--_refCount, this_+0, A_PtrSize, "UInt")
		if (_refCount == 0) {
			DllCall("CloseHandle", "Ptr", AsyncActionCompletedHandler_gethEvent(this_))
			,DllCall("GlobalFree", "Ptr", this_, "Ptr")
		}
	}
	return _refCount
}

class HSTRING {
	static lpWindowsCreateString := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", "combase.dll", "Ptr"), "AStr", "WindowsCreateString", "Ptr")
		  ,lpWindowsDeleteString := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", "combase.dll", "Ptr"), "AStr", "WindowsDeleteString", "Ptr")

	__New(sourceString, length := 0) {
		this._ := !DllCall(HSTRING.lpWindowsCreateString, "WStr", sourceString, "UInt", length ? length : StrLen(sourceString), "Ptr*", string) ? string : 0
	}

	__Delete() {
		DllCall(HSTRING.lpWindowsDeleteString, "Ptr", this._)
	}
}


; Bluetooth-headset connection code

FindAudDevice(device_desc, capture, unplugged, doRelease := True)
{
	; Based off VA_GetDevice
    static CLSID_MMDeviceEnumerator := "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
        , IID_IMMDeviceEnumerator := "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
        , DEVICE_STATE_ACTIVE := 0x00000001
        , DEVICE_STATE_UNPLUGGED := 0x00000008
;        , DEVICE_STATE_NOTPRESENT := 0x00000004

    if !(deviceEnumerator := ComObjCreate(CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator))
        return 0
   
    device := 0

    if VA_IMMDeviceEnumerator_GetDevice(deviceEnumerator, device_desc, device) = 0
        goto FindAudDevice_Return

    if device_desc is integer
    {
        if device_desc >= 4096 ; Probably a device pointer, passed here indirectly via VA_GetAudioMeter or such.
            ObjAddRef(device := device_desc)
        goto FindAudDevice_Return
    }
    else
        RegExMatch(device_desc, "(.*?)\s*(?::(\d+))?$", m)

	if m1 =
        goto FindAudDevice_Return

	VA_IMMDeviceEnumerator_EnumAudioEndpoints(deviceEnumerator, !!capture, unplugged ? DEVICE_STATE_UNPLUGGED : DEVICE_STATE_ACTIVE, devices)

    ,VA_IMMDeviceCollection_GetCount(devices, count)
    index := 0
    Loop % count
        if VA_IMMDeviceCollection_Item(devices, A_Index-1, device) = 0
            if InStr(VA_GetDeviceName(device), m1) && (m2 = "" || ++index = m2)
                goto FindAudDevice_Return
            else if (doRelease)
                ObjRelease(device), device:=0

FindAudDevice_Return:
	if (doRelease)
    {
        ObjRelease(deviceEnumerator)
        if devices
            ObjRelease(devices)
    }

    return device
}

DoWork(dev, disconnect, doRelease := True)
{
	static KSPROPSETID_BtAudio, cbKSPROPSETID := 24
    if !VarSetCapacity(KSPROPSETID_BtAudio)
        VarSetCapacity(KSPROPSETID_BtAudio, cbKSPROPSETID)
        ,VA_GUID(KSPROPSETID_BtAudio := "{7FA06C40-B8F6-4C7E-8556-E8C33A12E54D}")
		,NumPut(1, KSPROPSETID_BtAudio, 20, "UInt")

	if (VA_IMMDevice_Activate(dev, "{2A07407E-6497-4A18-9787-32F79BD0D98F}", 1, 0, dev_topology) == 0) {
		if (VA_IDeviceTopology_GetConnector(dev_topology, 0, conn) == 0) {
			if (VA_IConnector_GetConnectedTo(conn, conn_to) == 0) {
				try if ((part := ComObjQuery(conn_to, "{AE2DE0E4-5BCA-4F2D-AA46-5D13F8FDB3A9}"))) {
					if (VA_IPart_GetTopologyObject(part, part_topology) == 0) {
						if (VA_IDeviceTopology_GetDeviceId(part_topology, adapter_id) == 0) {
							if ((adapter_dev := VA_GetDevice(adapter_id))) {
								if (VA_IMMDevice_Activate(adapter_dev, "{28F54685-06FD-11D2-B27A-00A0C9223196}", 1, 0, KSControl) == 0) {
									NumPut(disconnect, KSPROPSETID_BtAudio, 16, "UInt")
									,DllCall(NumGet(NumGet(KSControl+0)+3*A_PtrSize), "Ptr", KSControl, "Ptr", &KSPROPSETID_BtAudio, "UInt", cbKSPROPSETID, "Ptr", 0, "UInt", 0, "Ptr", 0)
									if (doRelease)
										ObjRelease(KSControl)
								}
								if (doRelease)
									ObjRelease(adapter_dev)
							}
						}
						if (doRelease)
							ObjRelease(part_topology)
					}
					if (doRelease)
						ObjRelease(part)
				}
				if (doRelease)
					ObjRelease(conn_to)
			}
			if (doRelease)
				ObjRelease(conn)
		}
		if (doRelease)
			ObjRelease(dev_topology)
	}
}

ConnectHeadset(device_desc, capture := False, doRelease := True)
{
	if ((dev := FindAudDevice(device_desc, capture, True, doRelease))) {
		DoWork(dev, False, doRelease)
		if (doRelease)
			ObjRelease(dev)
	}
}

DisconnectHeadset(device_desc, capture := False)
{
	if ((dev := FindAudDevice(device_desc, capture, False))) {
		DoWork(dev, True)
		,ObjRelease(dev)
	}
}

DisableNoiseCancelling()
{
	; From https://github.com/dustbin1415/WinUI-SonyHeadphonesClient
	hModuleSonyHeadphonesClientDll := DllCall("LoadLibraryW", "WStr", A_ScriptDir . "\SonyHeadphonesClientDll.dll", "Ptr")
	if (!hModuleSonyHeadphonesClientDll)
		return

	try {
		VarSetCapacity(devices, 1180) ;, 0)
		,DllCall("SonyHeadphonesClientDll.dll\GetDevices", "Str", devices)
		;if (!StrGet(&devices, 100, "UTF-8"))
		;	return
		if (!DllCall("SonyHeadphonesClientDll.dll\ConnectDevice", "Int", 0))
			return
		DllCall("SonyHeadphonesClientDll.dll\SetFocusOnVoice", "Int", !DllCall("SonyHeadphonesClientDll.dll\GetFocusOnVoice"))
		,DllCall("SonyHeadphonesClientDll.dll\SetAmbientSoundControl", "Int", False)
		,DllCall("SonyHeadphonesClientDll.dll\SetChanges")
		,DllCall("SonyHeadphonesClientDll.dll\DisConnectDevice")
	} finally {
		DllCall("FreeLibrary", "Ptr", hModuleSonyHeadphonesClientDll)
	}
}
