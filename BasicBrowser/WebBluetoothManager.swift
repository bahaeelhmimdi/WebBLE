//
//  WebBluetooth.swift
//  BasicBrowser
//
//  Created by Paul Theriault on 10/01/2016.
//

import Foundation
import CoreBluetooth
import WebKit

open class WebBluetoothManager: NSObject, CBCentralManagerDelegate, WKScriptMessageHandler, PopUpPickerViewDelegate {
    
    override init(){
        super.init()
        centralManager.delegate = self
    }
    
    // BLE
    var centralManager:CBCentralManager! = CBCentralManager(delegate: nil, queue: nil)
    var devicePicker:PopUpPickerView!
    
    var BluetoothDeviceOption_filters:[CBUUID]?
    var BluetoothDeviceOption_optionalService:[CBUUID]?
    
    // Stores references to devices while scanning. Key is the system provided UUID (peripheral.id)
    var foundDevices:[String:BluetoothDevice] = [String:BluetoothDevice]()
    var deviceRequest:JSRequest? //stores the last requestID for device requests (i.e. subsequent request replace unfinished requests)
    var connectionRequest:JSRequest? // stores last conncetion request, to resolve when connected/disconnected
    var disconnectionRequest:JSRequest? // stores last conncetion request, to resolve when connected/disconnected

    
    // Allowed Devices Map
    // See https://webbluetoothcg.github.io/web-bluetooth/#per-origin-device-properties
    // Stores a dictionary for each origin which holds a mappping between Device ID and the actual BluetoothDevice
    // For example, if a user grants access for https://example.com  would be something like:
    //    allowedDevices["https://example.com"]?[NSUUID().UUIDString] = new BluetoothDevice(peripheral)
    var allowedDevices:[String:[String:BluetoothDevice]] = [String:[String:BluetoothDevice]]()
    
    // recieve message from javascript
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage){

        let messageBody = message.body as! NSDictionary
        let callbackID:Int =  messageBody["callbackID"] as! Int
        let type = messageBody["type"] as! String
        let data = messageBody["data"] as! [String:AnyObject]
        
        //todo add safety
        let req = JSRequest(id: callbackID,type:type,data:data,webView:message.webView!);
        print("<-- #\(callbackID) to dispatch \(type) with data:\(data)")
        processRequest(req)

        /*var args:[AnyObject]=[AnyObject]()
        if(messageBody["arguments"] != nil){
            args = transformArguments(messageBody["arguments"] as! [AnyObject])
        }*/
    }
    
    func processRequest(_ req:JSRequest){
        switch req.type{
        case "bluetooth:requestDevice":
            if scanForPeripherals(req.data){
                deviceRequest = req
                devicePicker.showPicker()
            }
            else{
                req.sendMessage("response", success:false, result:"\"Bluetooth is currently disabled\"", requestId:req.id)
            }
            
        case "bluetooth:deviceMessage":
            print("DeviceMessage for \(req.deviceId)")
            print("Calling \(req.method) with \(req.args)")
            print(req.args)
            
            if let device = allowedDevices[req.origin]?[req.deviceId]{
                //connecting/disconnecting GATT server has to be handle by the manager
                if(req.method == "BluetoothRemoteGATTServer.connect"){
                    centralManager.connect(device.peripheral,options: nil)
                    connectionRequest = req //resolved when connected
                }else if (req.method == "BluetoothRemoteGATTServer.disconnect"){
                    centralManager.cancelPeripheralConnection(device.peripheral)
                    disconnectionRequest = req //resolved when connected
                }else{
                     device.recieve(req)
                }
            }
            else{
                req.sendMessage("response", success:false, result:"\"Device not found\"", requestId:req.id)
            }
        default:
            let error="\"Unknown method: \(req.type)\"";
            req.sendMessage("response", success:false, result:error, requestId:req.id)
        }

    }
    
    
    
    func transformArguments(_ args: [AnyObject]) -> [AnyObject?] {
        return args.map { arg in
            if arg is NSNull {
                return nil
            } else {
                return arg
            }
        }
    }

    
    // Check status of BLE hardware
    open func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == CBCentralManagerState.poweredOn {
            print("Bluetooth is powered on")
        }
        else {
            print("Error:Bluetooth switched off or not initialized")
        }
    }
    
    func scanForPeripherals(_ options:[String:AnyObject]) -> Bool{
        if centralManager.state != CBCentralManagerState.poweredOn{
            return false
        }
        
        let filters = options["filters"] as! [AnyObject]
        let filterOne = filters[0]
        
        print("Filters",filters)
        print("Services",filterOne["services"])
        print("name:",filters[0]["name"])
        print("prefix:",filters[0]["namePrefix"])
        
        let services = filters[0]["services"] as! [String]
        
        let servicesCBUUID:[CBUUID]
        
        //todo validate CBUUID (js does this already but security should be here since
        //messageHandler can be called directly.
        // (if the string is invalid, it causes app to crash with NSexception)
        
        //todo: determine if uppercase is the standard (bb-b uses uppercase UUID)
        servicesCBUUID = services.map {return CBUUID(string:$0.uppercased())}
        
        foundDevices.removeAll();
        centralManager.scanForPeripherals(withServices: servicesCBUUID, options: nil)
        return true
    }
    
    open func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let deviceId = UUID().uuidString;
        foundDevices[peripheral.identifier.uuidString] = BluetoothDevice(deviceId:deviceId,peripheral: peripheral,
            advertisementData: advertisementData as [String : AnyObject],
            RSSI: RSSI)
        updatePickerData()
    }
    
    open func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected")
        if(connectionRequest != nil){
            connectionRequest!.sendMessage("response", success:true, result:"{}", requestId:connectionRequest!.id)
            connectionRequest = nil
        }
        
        
    }
    
    open func centralManager(_ central: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral) {
        print("Failed to connect")
        connectionRequest!.sendMessage("response", success:false, result:"'Failed to connect'", requestId:connectionRequest!.id)
        connectionRequest = nil
        
    }
    
    //UIPickerView protocols
    
    //2d array of devices & corresponding names
    var pickerNames:[String] = [String]()
    var pickerIds:[String] = [String]()
    
    func updatePickerData(){
        pickerNames.removeAll()
        pickerIds.removeAll()
        for (id, device) in foundDevices {
            pickerNames.append(device.peripheral.name ?? "Unknown")
            pickerIds.append(id)
        }
        devicePicker.updatePicker()
    }
    
  
    func numberOfComponentsInPickerView(_ pickerView: UIPickerView) -> Int {
        return 1
    }
    
    // The number of rows of data
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return pickerNames.count
    }
    
    // The data to return for the row and component (column) that's being passed in
    open func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return pickerNames[row]
    }
    
    func pickerView(_ pickerView: UIPickerView, didSelect numbers: [Int]) {
        
        if(pickerIds.count<1){
            return
        }
        let deviceId = pickerIds[numbers[0]]
        centralManager.stopScan()
        
        if deviceRequest == nil{
            print("Picker UI initiated with a request, this should never happen")
            return
        }
        let req = deviceRequest!
        deviceRequest = nil
        
        if self.foundDevices[deviceId] == nil{
            print("DEVICE OUT OF RANGE")
            return
        }
        let device = self.foundDevices[deviceId]!
        let deviceJSON = device.toJSON()!
        
        if allowedDevices[req.origin] == nil{
            allowedDevices[req.origin] = [String:BluetoothDevice]()
        }
        //add device to allowed list, and resolve requestDevice promise
        allowedDevices[req.origin]![device.deviceId] = device
        req.sendMessage("response", success:true, result:deviceJSON, requestId:req.id)
        
    }
}
