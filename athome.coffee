
module.exports = (env) ->

  convict = env.require "convict"

  # Require the [Q](https://github.com/kriskowal/q) promise library
  Q = env.require 'q'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  # Require the [SerialPort] (https://github.com/voodootikigod/node-serialport)
  {SerialPort} = require 'serialport'

  _ = env.require 'lodash'
 
  # the plugin class
  class AtHomePlugin extends env.plugins.Plugin

    @transport

    init: (app, @framework, config) ->
      env.logger.info "atHome: init"

      @conf = convict _.cloneDeep(require("./athome-plugin-config-schema"))

      @conf.load config
      @conf.validate()

      @isDemo = @conf.get "demo"

      serialName = @conf.get "serialDeviceName"
      env.logger.info "atHome: init with serial device name #{serialName}  demo #{@isDemo}"

      @cmdReceivers = [];

      if !@isDemo
        @transport = new AHTransport serialName, @receiveCommandCallback      
      

    createDevice: (deviceConfig) ->
      env.logger.info "atHome: createDevice #{deviceConfig.id}"
      return switch deviceConfig.class
        when 'AHSwitchFS20' 
          @framework.registerDevice(new AHSwitchFS20 deviceConfig)
          true
        when 'AHSwitchElro' 
          @framework.registerDevice(new AHSwitchElro deviceConfig)
          true
        when 'AHRCSwitchElro'
          rswitch = new AHRCSwitchElro deviceConfig
          @cmdReceivers.push rswitch
          @framework.registerDevice(rswitch)
          true
        when 'AHSensorValue'
          value = new AHSensorValue deviceConfig, @isDemo
          @cmdReceivers.push value
          @framework.registerDevice(value)
          true
        else
          false

    sendCommand: (id, cmdString) ->
      if !@isDemo
        @transport.sendCommand id, cmdString

    receiveCommandCallback: (cmdString) =>
      for cmdReceiver in @cmdReceivers
        handled = cmdReceiver.handleReceivedCmd cmdString
        break if handled
      
  
  # AHTransport handles the communication with the arduino      
  class AHTransport

    @serial

    constructor: (serialPortName, @receiveCommandHandler) ->
      
      @cmdString = ""
      @serial = new SerialPort serialPortName, baudrate: 57600, false

      @serial.open (err) ->
        if ( err? )
          env.logger.info "open serialPort #{serialPortName} failed #{err}"
        else
          env.logger.info "open serialPort #{serialPortName}"
      
   
      @serial.on 'open', ->
         @.write('echo\n');
   
      @serial.on 'error', (err) -> 
         env.logger.error "atHome: serial error #{err}"
   
      @serial.on 'data', (data) =>
        env.logger.debug "atHome: serial data received #{data}"
        dataString = "#{data}"

        # remove carriage return
        dataString = dataString.replace(/[\r]/g, '');

        # line feed ?       
        if dataString.indexOf('\n') != -1
          parts = dataString.split '\n'
          @cmdString = @cmdString + parts[0]
          @receiveCommandHandler @cmdString
          if ( parts.length > 0 )
            @cmdString = parts[1]
          else
            @cmdString = ''         
        else
          @cmdString = @cmdString + dataString

    sendCommand: (id, cmdString) ->
      env.logger.debug "AtHomeTransport: #{id} sendCommand #{cmdString}"
      @serial.write(cmdString+'\n') 



  # AHSwitchFS20 controls FS20 devices
  class AHSwitchFS20 extends env.devices.PowerSwitch

    constructor: (deviceconfig) ->
      @conf = convict _.cloneDeep(require("./athome-device-fs20-config-schema"))
      @conf.load deviceconfig
      @conf.validate()

      @id = @conf.get "id"
      @name = @conf.get "name"
      @houseid = @conf.get "houseid"
      @deviceid = @conf.get "deviceid"

      super()

    
    changeStateTo: (state) ->
      if @_state is state then return Q true
      else return Q.fcall =>
        cmd = 'F '+@houseid+@deviceid
        atHomePlugin.sendCommand @id, (if state is on then cmd+'10' else cmd+'00')
        @_setState state


  # AHSwitchElro controls ELRO power points
  class AHSwitchElro extends env.devices.PowerSwitch

    constructor: (deviceconfig) ->
      @conf = convict _.cloneDeep(require("./athome-device-elro-config-schema"))
      @conf.load deviceconfig
      @conf.validate()

      @id = @conf.get "id"
      @name = @conf.get "name"
      @houseid = @conf.get "houseid"
      @deviceid = @conf.get "deviceid"

      super()

    
    changeStateTo: (state) ->
      if @_state is state then return Q true
      else return Q.fcall =>
        cmd = 'E '+@houseid+' '+@deviceid
        atHomePlugin.sendCommand @id, (if state is on then cmd+' 1' else cmd+' 0')
        @_setState state



  # AHRCSwitchElro is a switch which state can be changed be the ui or by an ELRO Remote control
  class AHRCSwitchElro extends env.devices.PowerSwitch
  
    constructor: (deviceconfig) ->
      @conf = convict _.cloneDeep(require("./athome-device-elro-config-schema"))
      @conf.load deviceconfig
      @conf.validate()

      @id = @conf.get "id"
      @name = @conf.get "name"
      @houseid = @conf.get "houseid"
      @deviceid = @conf.get "deviceid"

      @changeStateTo off

      super()

    changeStateTo: (state) ->
      if @_state is state then return Q true
      else return Q.fcall =>
        @_setState state

    handleReceivedCmd: (command) ->
      params = command.split " "
      
      return false if params.length < 4 or params[0] != "E" or params[1] != @houseid or params[2] != @deviceid
      
      if ( params[3] == '1' ) 
        @changeStateTo on
      else 
        @changeStateTo off
      
      return true;


  # AHSensorValue handles arduino delivered measure values like voltage, temperatue, ...
  class AHSensorValue extends env.devices.Sensor
    value: null

    getTemplateName: -> "device"

    constructor: (deviceconfig, demo) ->
      @conf = convict _.cloneDeep(require("./athome-sensorvalue-config-schema"))
      @conf.load deviceconfig
      @conf.validate()

      @id = @conf.get "id"
      @name = @conf.get "name"
      @sensorid = @conf.get "sensorid"
      @scale = @conf.get "scale"
      @offset = @conf.get "offset"
      @value = 0
      
      @attributes =    
        value:
          description: "the sensor value"
          type: Number
          label:@conf.get "label"
          unit:@conf.get "unit"

      # update the value every 3 seconds
      if demo
        setInterval(=> 
          @updateDemoValue()
        , 3000)
      
      super()
 
    getValue: -> Q(@value)
 
    handleReceivedCmd: (command) ->
      params = command.split " "
      
      return false if params.length < 3 or params[0] != "SV" or params[1] != @sensorid
      
      @value = parseInt(params[2], 10)*@scale + @offset
      @emit "value", @value
      return true;

    updateDemoValue: () ->
      @value = @value+50
      @emit "value", @value
 
 
 
 
  atHomePlugin = new AtHomePlugin
  return atHomePlugin
  
  