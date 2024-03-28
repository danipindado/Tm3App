using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.BluetoothLowEnergy as Ble;
using Toybox.Application;
import  Toybox.Lang;

class Logger {
  var minSeverity;

  // Initialization function to set minimum severity level
  function initLogger(minSeverity) {
    self.minSeverity = minSeverity;
  }

  // Logging functions
  function logDebug(msg) {
    if (minSeverity <= 0) {
      System.println("[DEBUG]  " + msg);
    }
  }

  function logInfo(msg) {
    if (minSeverity <= 1) {
      System.println("[INFO]  " + msg);
    }
  }

  function logWarn(msg) {
    if (minSeverity <= 2) {
      System.println("[WARN]  " + msg);
    }
  }

  function logError(msg) {
    if (minSeverity <= 3) {
      System.println("[ERROR]  " + msg);
    }
  }
}

// base class
class baseView extends WatchUi.SimpleDataField {
  var displayString = "";

  function initialize() {
    SimpleDataField.initialize();

    //label = "Wheee";		// seems this has to be set in initialize() and can't be changed later
  }

  function setLabelInInitialize(s) {
    label = s;
  }

  // This method is called once per second and automatically provides Activity.Info to the DataField object for display or additional computation.
  function compute(info) {
    return displayString;
  }
}

class Tm3View extends baseView {
  var thisView; // reference to self, lovely
  var logger;
  var bleHandler; // the BLE delegate

  var showList = [0, 0, 0]; // 3 user settings for which values to show
  var lastLock = false; // user setting for lock to MAC address (or not)
  var lastMACArray = null; // byte array of MAC address of bike

  var batteryValue = -1; // battery % to display
  var modeValue = -1; // assist mode to display
  var gearValue = -1; // gear number to display
  var cadenceValue = -1; // cadence to display
  var currentSpeedValue = -1; // current speed to display
  var assistanceLevelValue = -1; // assistance level to display

  const secondsWaitBattery = 15; // only read the battery value every 15 seconds
  var secondsSinceReadBattery = secondsWaitBattery;

  var modeNamesDefault = ["Off", "Eco", "Trail", "Boost", "Walk"];

  var modeLettersDefault = ["O", "E", "T", "B", "W"];

  var modeNamesAlternate = ["Off", "Eco", "Norm", "High", "Walk"];

  var modeLettersAlternate = ["O", "E", "N", "H", "W"];

  var modeNames = modeNamesDefault;
  var modeLetters = modeLettersDefault;

  var connectCounter = 0; // number of seconds spent scanning/connecting to a bike

  // Safely read a boolean value from user settings
  function propertiesGetBoolean(p) {
    var v = Application.Properties.getValue(p);
    if (v == null || !(v instanceof Boolean)) {
      v = false;
    }
    return v;
  }

  // Safely read a number value from user settings
  function propertiesGetNumber(p) {
    var v = Application.Properties.getValue(p);
    if (v == null || v instanceof Boolean) {
      v = 0;
    } else if (!(v instanceof Number)) {
      v = v.toNumber();
      if (v == null) {
        v = 0;
      }
    }
    return v;
  }

  // Safely read a string value from user settings
  function propertiesGetString(p) {
    var v = Application.Properties.getValue(p);
    if (v == null) {
      v = "";
    } else if (!(v instanceof String)) {
      v = v.toString();
    }
    return v;
  }

  // read the user settings and store locally
  function getUserSettings() {
    showList[0] = propertiesGetNumber("Item1");
    showList[1] = propertiesGetNumber("Item2");
    showList[2] = propertiesGetNumber("Item3");

    lastLock = propertiesGetBoolean("LastLock");

    var modeNamesStyle = propertiesGetNumber("ModeNames");
    if (modeNamesStyle == 1) {
      // 1 or 0 are the only valid values allowed
      modeNames = modeNamesAlternate;
      modeLetters = modeLettersAlternate;
    } else {
      modeNames = modeNamesDefault;
      modeLetters = modeLettersDefault;
    }

    // convert the MAC address string to a byte array
    // (if the string is an invalid format, e.g. contains the letter Z, then the byte array will be null)
    lastMACArray = null;
    var lastMAC = propertiesGetString("LastMAC");
    try {
      if (lastMAC.length() > 0) {
        lastMACArray = StringUtil.convertEncodedString(lastMAC, {
          :fromRepresentation => StringUtil.REPRESENTATION_STRING_HEX,
          :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
        });
      }
    } catch (e) {
      self.logger.logError("catch: " + e.getErrorMessage());
      lastMACArray = null;
    }
  }

  // Remember the current MAC address byte array, and also convert it to a string and store in the user settings
  function saveLastMACAddress(newMACArray) {
    if (newMACArray != null) {
      lastMACArray = newMACArray;
      try {
        var s = StringUtil.convertEncodedString(newMACArray, {
          :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
          :toRepresentation => StringUtil.REPRESENTATION_STRING_HEX,
        });
        Application.Properties.setValue("LastMAC", s.toUpper());
      } catch (e) {
        self.logger.logError("catch: " + e.getErrorMessage());
      }
    }
  }

  function initialize() {
    baseView.initialize();

    // label can only be set in initialize so don't bother storing it
    setLabelInInitialize(propertiesGetString("Label"));

    getUserSettings();
  }

  // called by app when settings change
  function onSettingsChanged() {
    getUserSettings();

    // do some stuff in case user has changed the MAC address or the lock flag
    if (bleHandler != null) {
      // if lastLock or lastMAC get changed dynamically while the field is running then should check if current bike connection is ok
      if (
        lastLock &&
        lastMACArray != null &&
        bleHandler.connectedMACArray != null
      ) {
        bleHandler.bleDisconnect();
      }

      // And lets clear the scanned list, as if a device was scanned and excluded previously, maybe now it shouldn't be
      bleHandler.deleteScannedList();
    }

    WatchUi.requestUpdate(); // update the view to reflect changes
  }

  // remember a reference to ourself as it's useful, but can't see a way in CIQ to access this otherwise?!
  function setSelf(theView) {
    thisView = theView;
    logger = new Logger();
    logger.initLogger(0);
    setupBle();
  }

  function setupBle() {
    bleHandler = new Tm3Delegate(thisView);
    Ble.setDelegate(bleHandler);
  }

  // This method is called once per second and automatically provides Activity.Info to the DataField object for display or additional computation.
  // Calculate a value and save it locally in this method.
  // Note that compute() and onUpdate() are asynchronous, and there is no guarantee that compute() will be called before onUpdate().
  function compute(info) {
    // quick test values
    //showList[0] = 1;	// battery
    //showList[1] = 2;	// mode
    //showList[2] = 5;	// gear

    var showBattery = showList[0] == 1 || showList[1] == 1 || showList[2] == 1;
    if (showBattery) {
      // only read battery value every 15 seconds once we have a value
      secondsSinceReadBattery++;
      if (batteryValue < 0 || secondsSinceReadBattery >= secondsWaitBattery) {
        secondsSinceReadBattery = 0;
        bleHandler.requestReadBattery();
      }
    }

    var showMode = showList[0] >= 2 || showList[1] >= 2 || showList[2] >= 2;
    bleHandler.requestNotifyMode(showMode); // set whether we want mode or not (continuously)

    bleHandler.compute();

    // create the string to display to user
    displayString = "";

    // could show status of scanning & pairing if we wanted
    if (bleHandler.isConnecting()) {
      if (!bleHandler.isRegistered()) {
        displayString = "BLE Start"; // + bleHandler.profileRegisterSuccessCount + ":" + bleHandler.profileRegisterFailCount;
      } else {
        connectCounter++;

        displayString = "Scan " + connectCounter;
      }
    } else {
      connectCounter = 0;

      for (var i = 0; i < showList.size(); i++) {
        switch (showList[i]) {
          case 0: {
            // off
            break;
          }

          case 1: {
            // battery
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (batteryValue >= 0 ? batteryValue : "--") +
              "%";
            break;
          }

          case 2: {
            // mode name
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (modeValue >= 0 && modeValue < modeNames.size()
                ? modeNames[modeValue]
                : "----");
            break;
          }

          case 3: {
            // mode letter
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (modeValue >= 0 && modeValue < modeLetters.size()
                ? modeLetters[modeValue]
                : "-");
            break;
          }

          case 4: {
            // mode number
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (modeValue >= 0 ? modeValue : "-");
            break;
          }

          case 5: {
            // gear
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (gearValue >= 0 ? gearValue : "-");
            break;
          }

          case 6: {
            // cadence
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (cadenceValue >= 0 ? cadenceValue : "-");
            break;
          }

          case 7: {
            // current speed
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (currentSpeedValue >= 0 ? currentSpeedValue.format("%.1f") : "-");
            break;
          }

          case 8: {
            // assistance level
            displayString +=
              (displayString.length() > 0 ? " " : "") +
              (assistanceLevelValue >= 0 ? assistanceLevelValue : "-");
            break;
          }
        }
      }
    }

    return baseView.compute(info); // if a SimpleDataField then this will return the string/value to display
  }
}

// This is the BLE delegate class
// I've just added all my BLE related stuff to here too
class Tm3Delegate extends Ble.BleDelegate {
  var mainView;

  enum {
    State_Init, // starting up
    State_Connecting, // scanning, choosing & connecting to a bike
    State_Idle, // reading data from our chosen bike
    State_Disconnected, // we've disconnected (so will need to scan etc again)
  }

  var state = State_Init;

  var connectedMACArray = null; // MAC address byte array of bike we are (successfully) connected to

  var currentScanning = false; // scanning turned on?
  var wantScanning = false; // do we want it on?

  // start the process of scanning for a bike to connect to
  function startConnecting() {
    mainView.batteryValue = -1;
    mainView.modeValue = -1;
    mainView.gearValue = -1;
    mainView.cadenceValue = -1;
    mainView.currentSpeedValue = -1;
    mainView.assistanceLevelValue = -1;

    state = State_Connecting;

    connectedMACArray = null;

    wantScanning = true;
    deleteScannedList();

    writingNotifyMode = false;
    currentNotifyMode = false;
  }

  // have the profiles been registered successfully?
  function isRegistered() {
    return profileRegisterSuccessCount >= 3;
  }

  // in the process of scanning & choosing a bike?
  function isConnecting() {
    return state == State_Connecting;
  }

  // successfully connected to our chosen bike?
  function isConnected() {
    return state == State_Idle;
  }

  var wantReadBattery = false;
  var waitingRead = false;

  // call this when you want a battery reading
  function requestReadBattery() {
    wantReadBattery = true;
  }

  var wantNotifyMode = false; // want notifications on?
  var waitingWrite = false; // waiting for the write action to complete (which turns on or off the notifications)
  var writingNotifyMode = false; // the on/off state we are currently in the process of writing
  var currentNotifyMode = false; // the current on/off state (that we know from completed writes)

  // call this to turn on/off notifications for the mode/gear/other data blocks
  function requestNotifyMode(wantMode) {
    wantNotifyMode = wantMode;
  }

  // initialize this delegate!
  function initialize(theView) {
    mainView = theView;

    BleDelegate.initialize();

    bleInitProfiles();

    startConnecting();
  }

  // called from compute of mainView
  function compute() {
    if (wantScanning != currentScanning) {
      Ble.setScanState(
        wantScanning ? Ble.SCAN_STATE_SCANNING : Ble.SCAN_STATE_OFF
      ); // Ble.SCAN_STATE_OFF, Ble.SCAN_STATE_SCANNING
    }

    switch (state) {
      case State_Connecting: {
        // scanning & pairing until we connect to the bike
        // waiting for onScanResults() to be called
        // and for it to decide to pair to something
        //
        // Maybe if scanning takes too long, then cancel it and try again in "a while"?
        // When View.onShow() is next called? (If user can switch between different pages ...)
        break;
      }

      case State_Idle: {
        // connected, so now reading data as needed
        // if there is no longer a paired device or it is not connected
        // then we have disconnected ...
        var d = Ble.getPairedDevices().next(); // get first device (since we only connect to one at a time)
        if (d == null || !d.isConnected()) {
          bleDisconnect();
          state = State_Disconnected;
        } else if (!waitingRead && !waitingWrite) {
          // do a read or write to the BLE device if we need to and nothing else is active
          if (wantReadBattery) {
            if (bleReadBattery()) {
              wantReadBattery = false; // since we've started reading it
              waitingRead = true;
            } else {
              mainView.batteryValue = -1; // read wouldn't start for some reason ...
            }
          }
        }
        break;
      }

      case State_Disconnected: {
        startConnecting(); // start scanning to connect again
        break;
      }
    }
  }

  var serviceUuid = Ble.stringToUuid("0000fff0-0000-1000-8000-00805f9b34fb");
  var notifyCharacteristicUuid = Ble.stringToUuid(
    "0000fff1-0000-1000-8000-00805f9b34fb"
  );
  var writeCharacteristicUuid = Ble.stringToUuid(
    "0000fff2-0000-1000-8000-00805f9b34fb"
  );

  var profileRegisterSuccessCount = 0;
  var profileRegisterFailCount = 0;

  // scanResult.getRawData() returns this:
  // [3, 25, 128, 4, 2, 1, 5, 17, 6, 0, 69, 76, 66, 95, 79, 78, 65, 77, 73, 72, 83, 255, 24, 0, 0, 5, 255, 74, 4, 1, 0]
  // Raw advertising data format: https://www.silabs.com/community/wireless/bluetooth/knowledge-base.entry.html/2017/02/10/bluetooth_advertisin-hGsf
  // And the data types: https://www.bluetooth.com/specifications/assigned-numbers/generic-access-profile/
  //
  // So decoding gives:
  // 3, 25, 128, 4, (25=appearance) 0x8004
  // 2, 1, 5, (1=flags)
  // 17, 6, 0, 69, 76, 66, 95, 79, 78, 65, 77, 73, 72, 83, 255, 24, 0, 0, (6=Incomplete List of 128-bit Service Class UUIDs)
  //     (This in hex is 00 45 4c 42 5f 4f 4e 41 4d 49 48 53 ff 18 00 00, which matches 000018ff-5348-494d-414e-4f5f424c4500)
  // 5, 255, 74, 4, 1, 0 (255=Manufacturer Specific Data) (74 04 == Shimano BLE company id, which in decimal is 1098)
  //
  // Note that scanResult.getManufacturerSpecificData(1098) returns [1, 0]

  // set up the ble profiles we will use (CIQ allows up to 3 luckily ...)
  function bleInitProfiles() {
    // read - battery
    var profile = {
      :uuid => serviceUuid,
      :characteristics => [
        {
          :uuid => notifyCharacteristicUuid,
        },
      ],
    };

    try {
      Ble.registerProfile(profile);
    } catch (e) {
      mainView.logger.logError("catch = " + e.getErrorMessage());
      //mainView.displayString = "err";
    }
  }

  function bleDisconnect() {
    var d = Ble.getPairedDevices().next(); // get first device (since we only connect to one at a time)
    if (d != null) {
      Ble.unpairDevice(d);
    }
  }

  function bleReadBattery() {
    var startedRead = false;

    // don't know if we can just keep calling requestRead() as often as we like without waiting for onCharacteristicRead() in between
    // but it seems to work ...
    // ... or maybe it doesn't, as always get a crash trying to call requestRead() after power off bike
    // After adding code to wait for the read to finish before starting a new one, then the crash doesn't happen.

    // get first device (since we only connect to one at a time) and check it is connected
    var d = Ble.getPairedDevices().next();
    if (d != null && d.isConnected()) {
      try {
        var ds = d.getService(serviceUuid);
        if (ds != null) {
          var dsc = ds.getCharacteristic(notifyCharacteristicUuid);
          if (dsc != null) {
            dsc.requestRead(); // had one exception from this when turned off bike, and now a symbol not found error 'Failed invoking <symbol>'
            startedRead = true;
          }
        }
      } catch (e) {
        mainView.logger.logError("catch = " + e.getErrorMessage());
      }
    }

    return startedRead;
  }

  function onProfileRegister(uuid, status) {
    mainView.logger.logDebug("onProfileRegister status=" + status);
    //mainView.displayString = "reg" + status;

    if (status == Ble.STATUS_SUCCESS) {
      profileRegisterSuccessCount += 1;
    } else {
      profileRegisterFailCount += 1;
    }
  }

  function onScanStateChange(scanState, status) {
    mainView.logger.logDebug(
      "onScanStateChange scanState=" + scanState + " status=" + status
    );
    currentScanning = scanState == Ble.SCAN_STATE_SCANNING;

    deleteScannedList();
  }

  private function iterContains(iter, obj) {
    for (var uuid = iter.next(); uuid != null; uuid = iter.next()) {
      mainView.logger.logDebug("uuid " + uuid);
      if (uuid.equals(obj)) {
        return true;
      }
    }

    return false;
  }

  var scannedList = []; // array of scan results that have been tested and deemed not worthy of connecting to
  const maxScannedListSize = 10; // choose a max size just in case

  function addToScannedList(r) {
    // if reached max size of scan list remove the first (oldest) one
    if (scannedList.size() >= maxScannedListSize) {
      scannedList = scannedList.slice(1, maxScannedListSize);
    }

    // add new scan result to end of our scan list
    scannedList.add(r);
  }

  function deleteScannedList() {
    scannedList = new [0]; // new zero length array
  }

  // If a scan is running this will be called when new ScanResults are received
  function onScanResults(scanResults) {
    mainView.logger.logDebug("onScanResults");

    if (!wantScanning) {
      return;
    }

    for (;;) {
      var r = scanResults.next();
      if (r == null) {
        break;
      }
        
      mainView.logger.logDebug("getDeviceName " + r.getDeviceName());

      if(r.getDeviceName().equals("FS-ABFEBE")){
        // identify a FLV5 forumslader device by it's advertised manufacturer ID
        var iter = r.getManufacturerSpecificDataIterator();
        for (var dict = iter.next() as Dictionary; dict != null; dict = iter.next()) {
            mainView.logger.logDebug("companyId " + dict.get(:companyId));
            mainView.logger.logDebug("data " + dict.get(:data));  
          }    
          mainView.logger.logDebug("pairing " + r.getDeviceName());
          var d = Ble.pairDevice(r);
          if (d != null) {
            // it seems that sometimes after pairing onConnectedStateChanged() is not always called
            // - checking isConnected() here immediately seems to avoid that case happening.
            // if (d.isConnected()) {
              mainView.logger.logDebug("isConnected");
              Ble.setScanState(Ble.SCAN_STATE_OFF);
            // }

            //mainView.displayString = "paired " + d.getName();
          } else {
              mainView.logger.logDebug("isConnected null");
          }
        
      }
    }
  }

  // After pairing a device this will be called after the connection is made.
  // (But seemingly not sometimes ... maybe if still connected from previous run of datafield?)
  function onConnectedStateChanged(device, connectionState) {
      mainView.logger.logDebug("connectionState ",connectionState);
    if (connectionState == Ble.CONNECTION_STATE_CONNECTED) {
      mainView.logger.logDebug("onConnectedStateChanged");
      // startReadingMAC();
    }
  }

  // After requesting a read operation on a characteristic using Characteristic.requestRead() this function will be called when the operation is completed.
  function onCharacteristicRead(characteristic, status, value) {
    if (characteristic.getUuid().equals(notifyCharacteristicUuid)) {
      if (value != null && value.size() > 0) {
        // (had this return a zero length array once ...)
        mainView.batteryValue = value[0].toNumber(); // value is a byte array
      }
    }

    waitingRead = false;
  }

  // After requesting a write operation on a descriptor using Descriptor.requestWrite() this function will be called when the operation is completed.
  function onDescriptorWrite(descriptor, status) {
    var cd = descriptor.getCharacteristic();
    if (cd != null && cd.getUuid().equals(writeCharacteristicUuid)) {
      if (status == Ble.STATUS_SUCCESS) {
        currentNotifyMode = writingNotifyMode;
      }
    }

    waitingWrite = false;
  }

  // After enabling notifications or indications on a characteristic (by enabling the appropriate bit of the CCCD of the characteristic)
  // this function will be called after every change to the characteristic.
  function onCharacteristicChanged(characteristic, value) {
    if (characteristic.getUuid().equals(writeCharacteristicUuid)) {
      if (value != null) {
        // value is a byte array
        if (value.size() == 10) {
          // we want the one which is 10 bytes long (out of the 3 that Shimano seem to spam ...)
          mainView.modeValue = value[1].toNumber(); // and it is the 2nd byte of the array
          mainView.cadenceValue = value[5].toNumber();
          mainView.currentSpeedValue =
            ((value[3] << 8) | value[2]).toFloat() / 10;
          mainView.assistanceLevelValue = value[4].toNumber();
        } else if (value.size() == 17) {
          mainView.gearValue = value[5].toNumber();
        }
      }
    }
  }
}
