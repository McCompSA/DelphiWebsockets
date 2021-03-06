unit IdHTTPWebsocketClient;

interface

uses
  Classes,
  IdHTTP,
  {$IF CompilerVersion <= 21.0}  //D2010
  IdHashSHA1,
  {$else}
  Types,
  IdHashSHA,                     //XE3 etc
  {$IFEND}
  IdIOHandler,
  IdIOHandlerWebsocket,
//  {$ifdef FMX}
//  FMX.Types,
//  {$ELSE}
//  ExtCtrls,
//  {$ENDIF}
  IdWinsock2, Generics.Collections, SyncObjs,
  IdSocketIOHandling, IdIOHandlerStack;

type
  TWebsocketMsgBin  = procedure(const aData: TStream) of object;
  TWebsocketMsgText = procedure(const aData: string) of object;

  TIdHTTPWebsocketClient = class;
  TSocketIOMsg = procedure(const AClient: TIdHTTPWebsocketClient; const aText: string; aMsgNr: Integer) of object;

  TIdSocketIOHandling_Ext = class(TIdSocketIOHandling)
  end;

  TIdHTTPWebsocketClient = class(TIdHTTP)
  private
    FWSResourceName: string;
    FHash: TIdHashSHA1;
    FOnData: TWebsocketMsgBin;
    FOnTextData: TWebsocketMsgText;
    FNoAsyncRead: Boolean;
    FWriteTimeout: Integer;
    FUseSSL: boolean;
    FWebsocketImpl: TWebsocketImplementationProxy;
    function  GetIOHandlerWS: TWebsocketImplementationProxy;
    procedure SetOnData(const Value: TWebsocketMsgBin);
    procedure SetOnTextData(const Value: TWebsocketMsgText);
    procedure SetWriteTimeout(const Value: Integer);
    function GetIOHandler: TIdIOHandlerStack;
    procedure SetIOHandlerStack(const Value: TIdIOHandlerStack);
  protected
    FSocketIOCompatible: Boolean;
    FSocketIOHandshakeResponse: string;
    FSocketIO: TIdSocketIOHandling_Ext;
    FSocketIOContext: ISocketIOContext;
    FSocketIOConnectBusy: Boolean;

    //FHeartBeat: TTimer;
    //procedure HeartBeatTimer(Sender: TObject);
    function  GetSocketIO: TIdSocketIOHandling;
  protected
    procedure InternalUpgradeToWebsocket(aRaiseException: Boolean; out aFailedReason: string);virtual;
    function  MakeImplicitClientHandler: TIdIOHandler; override;
  public
    procedure AsyncDispatchEvent(const aEvent: TStream); overload; virtual;
    procedure AsyncDispatchEvent(const aEvent: string); overload; virtual;
    procedure ResetChannel;
  public
    procedure  AfterConstruction; override;
    destructor Destroy; override;

    function  TryUpgradeToWebsocket: Boolean;
    procedure UpgradeToWebsocket;

    function  TryLock: Boolean;
    procedure Lock;
    procedure UnLock;

    procedure Connect; override;
    procedure ConnectAsync; virtual;
    function  TryConnect: Boolean;
    procedure Disconnect(ANotifyPeer: Boolean); override;

    function  CheckConnection: Boolean;
    procedure Ping;
    procedure ReadAndProcessData;

    property  IOHandler: TIdIOHandlerStack read GetIOHandler write SetIOHandlerStack;
    property  IOHandlerWS: TWebsocketImplementationProxy read GetIOHandlerWS; // write SetIOHandlerWS;

    //websockets
    property  OnBinData : TWebsocketMsgBin read FOnData write SetOnData;
    property  OnTextData: TWebsocketMsgText read FOnTextData write SetOnTextData;

    property  NoAsyncRead: Boolean read FNoAsyncRead write FNoAsyncRead;

    //https://github.com/LearnBoost/socket.io-spec
    property  SocketIOCompatible: Boolean read FSocketIOCompatible write FSocketIOCompatible;
    property  SocketIO: TIdSocketIOHandling read GetSocketIO;
  published
    property  Host;
    property  Port;
    property  WSResourceName: string read FWSResourceName write FWSResourceName;
    property  UseSSL: boolean        read FUseSSL write FUseSSL;

    property  WriteTimeout: Integer read FWriteTimeout write SetWriteTimeout default 2000;
  end;

  TWSThreadList = class(TThreadList)
  public
    function Count: Integer;
  end;

  TIdWebsocketMultiReadThread = class(TThread)
  private
    class var FInstance: TIdWebsocketMultiReadThread;
  protected
    FReadTimeout: Integer;
    FTempHandle: THandle;
    FPendingBreak: Boolean;
    Freadset, Fexceptionset: TFDSet;
    Finterval: TTimeVal;
    procedure InitSpecialEventSocket;
    procedure ResetSpecialEventSocket;
    procedure BreakSelectWait;
  protected
    FChannels: TThreadList;
    FReconnectlist: TWSThreadList;
    FReconnectThread: TIdWebsocketQueueThread;
    procedure ReadFromAllChannels;
    procedure PingAllChannels;

    procedure Execute; override;
  public
    procedure  AfterConstruction;override;
    destructor Destroy; override;

    procedure Terminate;

    procedure AddClient   (aChannel: TIdHTTPWebsocketClient);
    procedure RemoveClient(aChannel: TIdHTTPWebsocketClient);

    property ReadTimeout: Integer read FReadTimeout write FReadTimeout default 5000;

    class function  Instance: TIdWebsocketMultiReadThread;
    class procedure RemoveInstance(aForced: boolean = false);
  end;

  //async process data
  TIdWebsocketDispatchThread = class(TIdWebsocketQueueThread)
  private
    class var FInstance: TIdWebsocketDispatchThread;
  public
    class function  Instance: TIdWebsocketDispatchThread;
    class procedure RemoveInstance(aForced: boolean = false);
  end;

implementation

uses
  IdCoderMIME, SysUtils, Math, IdException, IdStackConsts, IdStack,
  IdStackBSDBase, IdGlobal, Windows, StrUtils, DateUtils;

var
  GUnitFinalized: Boolean = false;

{ TIdHTTPWebsocketClient }

procedure TIdHTTPWebsocketClient.AfterConstruction;
begin
  inherited;
  FHash := TIdHashSHA1.Create;

  //IOHandler := TIdIOHandlerWebsocket.Create(nil);
  //IOHandler.RealIOHandler.UseNagle := False;
  //ManagedIOHandler := True;

  FSocketIO  := TIdSocketIOHandling_Ext.Create;
//  FHeartBeat := TTimer.Create(nil);
//  FHeartBeat.Enabled := False;
//  FHeartBeat.OnTimer := HeartBeatTimer;

  FWriteTimeout  := 2 * 1000;
  ConnectTimeout := 2000;
end;

procedure TIdHTTPWebsocketClient.AsyncDispatchEvent(const aEvent: TStream);
var
  strmevent: TMemoryStream;
begin
  if not Assigned(OnBinData) then Exit;

  strmevent := TMemoryStream.Create;
  strmevent.CopyFrom(aEvent, aEvent.Size);

  //events during dispatch? channel is busy so offload event dispatching to different thread!
  TIdWebsocketDispatchThread.Instance.QueueEvent(
    procedure
    begin
      if Assigned(OnBinData) then
        OnBinData(strmevent);
      strmevent.Free;
    end);
end;

procedure TIdHTTPWebsocketClient.AsyncDispatchEvent(const aEvent: string);
begin
  {$IFDEF DEBUG_WS}
  if DebugHook <> 0 then
    OutputDebugString(PChar('AsyncDispatchEvent: ' + aEvent) );
  {$ENDIF}

  //if not Assigned(OnTextData) then Exit;
  //events during dispatch? channel is busy so offload event dispatching to different thread!
  TIdWebsocketDispatchThread.Instance.QueueEvent(
    procedure
    begin
      if FSocketIOCompatible then
        FSocketIO.ProcessSocketIORequest(FSocketIOContext as TSocketIOContext, aEvent)
      else if Assigned(OnTextData) then
        OnTextData(aEvent);
    end);
end;

function TIdHTTPWebsocketClient.CheckConnection: Boolean;
begin
  Result := False;
  try
    if (IOHandler <> nil) and
       not IOHandler.ClosedGracefully and
      IOHandler.Connected then
    begin
      IOHandler.CheckForDisconnect(True{error}, True{ignore buffer, check real connection});
      Result := True;  //ok if we reach here
    end;
  except
    on E:Exception do
    begin
      //clear inputbuffer, otherwise it stays connected :(
//      if (IOHandler <> nil) then
//        IOHandler.Clear;
      Disconnect(False);
      if Assigned(OnDisConnected) then
        OnDisConnected(Self);
    end;
  end;
end;

procedure TIdHTTPWebsocketClient.Connect;
begin
  Lock;
  try
    if Connected then
    begin
      TryUpgradeToWebsocket;
      Exit;
    end;

    //FHeartBeat.Enabled := True;
    if SocketIOCompatible and
       not FSocketIOConnectBusy then
    begin
      //FSocketIOConnectBusy := True;
      //try
        TryUpgradeToWebsocket;     //socket.io connects using HTTP, so no seperate .Connect needed (only gives Connection closed gracefully exceptions because of new http command)
      //finally
      //  FSocketIOConnectBusy := False;
      //end;
    end
    else
    begin
      //clear inputbuffer, otherwise it can't connect :(
      if (IOHandlerWS <> nil) then IOHandlerWS.Clear;
      inherited Connect;
    end;
  finally
    UnLock;
  end;
end;

procedure TIdHTTPWebsocketClient.ConnectAsync;
begin
  TIdWebsocketMultiReadThread.Instance.AddClient(Self);
end;

destructor TIdHTTPWebsocketClient.Destroy;
//var tmr: TObject;
begin
//  tmr := FHeartBeat;
//  FHeartBeat := nil;
//  TThread.Queue(nil,    //otherwise free in other thread than created
//    procedure
//    begin
      //FHeartBeat.Free;
//      tmr.Free;
//    end);

  //TIdWebsocketMultiReadThread.Instance.RemoveClient(Self);
  DisConnect(True);
  FSocketIO.Free;
  FHash.Free;
  inherited;
end;

procedure TIdHTTPWebsocketClient.DisConnect(ANotifyPeer: Boolean);
begin
  if not SocketIOCompatible and
     ( (IOHandlerWS <> nil) and not IOHandlerWS.IsWebsocket)
  then
    TIdWebsocketMultiReadThread.Instance.RemoveClient(Self);

  if ANotifyPeer and SocketIOCompatible then
    FSocketIO.WriteDisConnect(FSocketIOContext as TSocketIOContext)
  else
    FSocketIO.FreeConnection(FSocketIOContext as TSocketIOContext);

//  IInterface(FSocketIOContext)._Release;
  FSocketIOContext := nil;

  Lock;
  try
    if IOHandler <> nil then
    begin
    IOHandlerWS.Lock;
      try
      IOHandlerWS.IsWebsocket := False;

      Self.ManagedIOHandler := False;       //otherwise it gets freed while we have a lock on it...
        inherited DisConnect(ANotifyPeer);
        //clear buffer, other still "connected"
      IOHandlerWS.Clear;

        //IOHandler.Free;
        //IOHandler := TIdIOHandlerWebsocket.Create(nil);
      finally
      IOHandlerWS.Unlock;
      end;
    end;
  finally
    UnLock;
  end;
end;

function TIdHTTPWebsocketClient.GetIOHandler: TIdIOHandlerStack;
begin
  Result := inherited IOHandler as TIdIOHandlerStack;
  if Result = nil then
begin
    inherited IOHandler := MakeImplicitClientHandler;
    Result    := inherited IOHandler as TIdIOHandlerStack;
  end;
end;

function TIdHTTPWebsocketClient.GetIOHandlerWS: TWebsocketImplementationProxy;
begin
  if FWebsocketImpl = nil then
      begin
    inherited IOHandler := Self.MakeImplicitClientHandler;
    Assert(FWebsocketImpl <> nil);
      end;

  Result := FWebsocketImpl;
  end;

function TIdHTTPWebsocketClient.GetSocketIO: TIdSocketIOHandling;
begin
  Result := FSocketIO;
end;

function TIdHTTPWebsocketClient.TryConnect: Boolean;
begin
  Lock;
  try
    try
      if Connected then Exit(True);

      Connect;
      Result := Connected;
      //if Result then
      //  Result := TryUpgradeToWebsocket     already done in connect
    except
      Result := False;
    end
  finally
    UnLock;
  end;
end;

function TIdHTTPWebsocketClient.TryLock: Boolean;
begin
  Result := System.TMonitor.TryEnter(Self);
end;

function TIdHTTPWebsocketClient.TryUpgradeToWebsocket: Boolean;
var
  sError: string;
begin
  try
    FSocketIOConnectBusy := True;
    Lock;
    try
      if (IOHandler <> nil) and IOHandlerWS.IsWebsocket then Exit(True);

      InternalUpgradeToWebsocket(False{no raise}, sError);
      Result := (sError = '');
    finally
      FSocketIOConnectBusy := False;
      UnLock;
    end;
  except
    Result := False;
  end;
end;

procedure TIdHTTPWebsocketClient.UnLock;
begin
  System.TMonitor.Exit(Self);
end;

procedure TIdHTTPWebsocketClient.UpgradeToWebsocket;
var
  sError: string;
begin
  Lock;
  try
    if IOHandler = nil then
      Connect
    else if not IOHandlerWS.IsWebsocket then
      InternalUpgradeToWebsocket(True{raise}, sError);
  finally
    UnLock;
  end;
end;

procedure TIdHTTPWebsocketClient.InternalUpgradeToWebsocket(aRaiseException: Boolean; out aFailedReason: string);
var
  sURL: string;
  strmResponse: TMemoryStream;
  i: Integer;
  sKey, sResponseKey: string;
  sSocketioextended: string;
  bLocked: boolean;
begin
  Assert((IOHandler = nil) or not IOHandlerWS.IsWebsocket);
  //remove from thread during connection handling
  TIdWebsocketMultiReadThread.Instance.RemoveClient(Self);

  bLocked := False;
  strmResponse := TMemoryStream.Create;
  Self.Lock;
  try
    //reset pending data
    if IOHandler <> nil then
    begin
      IOHandlerWS.Lock;
      bLocked := True;
      if IOHandlerWS.IsWebsocket then Exit;
      IOHandlerWS.Clear;
    end;

    //special socket.io handling, see https://github.com/LearnBoost/socket.io-spec
    if SocketIOCompatible then
    begin
      Request.Clear;
      Request.Connection := 'keep-alive';

      if UseSSL then
        sURL := Format('https://%s:%d/socket.io/1/', [Host, Port])
      else
        sURL := Format('http://%s:%d/socket.io/1/', [Host, Port]);

      strmResponse.Clear;

      ReadTimeout := 5 * 1000;
      if DebugHook > 0 then
        ReadTimeout := ReadTimeout * 10;

      //get initial handshake
      Post(sURL, strmResponse, strmResponse);
      if ResponseCode = 200 {OK} then
      begin
        //if not Connected then  //reconnect
        //  Self.Connect;
        strmResponse.Position := 0;
        //The body of the response should contain the session id (sid) given to the client,
        //followed by the heartbeat timeout, the connection closing timeout, and the list of supported transports separated by :
        //4d4f185e96a7b:15:10:websocket,xhr-polling
        with TStreamReader.Create(strmResponse) do
        try
          FSocketIOHandshakeResponse := ReadToEnd;
        finally
          Free;
        end;
        sKey := Copy(FSocketIOHandshakeResponse, 1, Pos(':', FSocketIOHandshakeResponse)-1);
        sSocketioextended := 'socket.io/1/websocket/' + sKey;
        WSResourceName := sSocketioextended;
      end
      else
      begin
        aFailedReason := Format('Initial socket.io handshake failed: "%d: %s"',[ResponseCode, ResponseText]);
        if aRaiseException then
          raise EIdWebSocketHandleError.Create(aFailedReason);
      end;
    end;

    Request.Clear;
    Request.CustomHeaders.Clear;
    strmResponse.Clear;
    //http://www.websocket.org/aboutwebsocket.html
    (* GET ws://echo.websocket.org/?encoding=text HTTP/1.1
     Origin: http://websocket.org
     Cookie: __utma=99as
     Connection: Upgrade
     Host: echo.websocket.org
     Sec-WebSocket-Key: uRovscZjNol/umbTt5uKmw==
     Upgrade: websocket
     Sec-WebSocket-Version: 13 *)

    //Connection: Upgrade
    Request.Connection := 'Upgrade';
    //Upgrade: websocket
    Request.CustomHeaders.Add('Upgrade:websocket');

    //Sec-WebSocket-Key
    sKey := '';
    for i := 1 to 16 do
      sKey := sKey + Char(Random(127-32) + 32);
    //base64 encoded
    sKey := TIdEncoderMIME.EncodeString(sKey);
    Request.CustomHeaders.AddValue('Sec-WebSocket-Key', sKey);
    //Sec-WebSocket-Version: 13
    Request.CustomHeaders.AddValue('Sec-WebSocket-Version', '13');
    Request.CustomHeaders.AddValue('Sec-WebSocket-Extensions', '');

    Request.CacheControl := 'no-cache';
    Request.Pragma := 'no-cache';
    Request.Host := Format('Host:%s:%d',[Host,Port]);
    Request.CustomHeaders.AddValue('Origin', Format('http://%s:%d',[Host,Port]) );
    //ws://host:port/<resourcename>
    //about resourcename, see: http://dev.w3.org/html5/websockets/ "Parsing WebSocket URLs"
    //sURL := Format('ws://%s:%d/%s', [Host, Port, WSResourceName]);

    if UseSSL then
      sURL := Format('https://%s:%d/%s', [Host, Port, WSResourceName])
    else
      sURL := Format('http://%s:%d/%s', [Host, Port, WSResourceName]);

    ReadTimeout := Max(5 * 1000, ReadTimeout);
    if DebugHook > 0 then
      ReadTimeout := ReadTimeout * 10;

    { example:
    GET http://localhost:9222/devtools/page/642D7227-148E-47C2-B97A-E00850E3AFA3 HTTP/1.1
    Upgrade: websocket
    Connection: Upgrade
    Host: localhost:9222
    Origin: http://localhost:9222
    Pragma: no-cache
    Cache-Control: no-cache
    Sec-WebSocket-Key: HIqoAdZkxnWWH9dnVPyW7w==
    Sec-WebSocket-Version: 13
    Sec-WebSocket-Extensions: x-webkit-deflate-frame
    User-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/27.0.1453.116 Safari/537.36
    Cookie: __utma=1.2040118404.1366961318.1366961318.1366961318.1; __utmc=1; __utmz=1.1366961318.1.1.utmcsr=(direct)|utmccn=(direct)|utmcmd=(none); deviceorder=0123456789101112; MultiTouchEnabled=false; device=3; network_type=0
    }
    begin
      Get(sURL, strmResponse, [101]);

    //http://www.websocket.org/aboutwebsocket.html
    (* HTTP/1.1 101 WebSocket Protocol Handshake
       Date: Fri, 10 Feb 2012 17:38:18 GMT
       Connection: Upgrade
       Server: Kaazing Gateway
       Upgrade: WebSocket
       Access-Control-Allow-Origin: http://websocket.org
       Access-Control-Allow-Credentials: true
       Sec-WebSocket-Accept: rLHCkw/SKsO9GAH/ZSFhBATDKrU=
       Access-Control-Allow-Headers: content-type *)

    //'HTTP/1.1 101 Switching Protocols'
      if ResponseCode <> 101 then
    begin
        aFailedReason := Format('Error while upgrading: "%d: %s"',[ResponseCode, ResponseText]);
      if aRaiseException then
        raise EIdWebSocketHandleError.Create(aFailedReason)
      else
        Exit;
    end;
    //connection: upgrade
    if not SameText(Response.Connection, 'upgrade') then
    begin
      aFailedReason := Format('Connection not upgraded: "%s"',[Response.Connection]);
      if aRaiseException then
        raise EIdWebSocketHandleError.Create(aFailedReason)
      else
        Exit;
    end;
    //upgrade: websocket
    if not SameText(Response.RawHeaders.Values['upgrade'], 'websocket') then
    begin
      aFailedReason := Format('Not upgraded to websocket: "%s"',[Response.RawHeaders.Values['upgrade']]);
      if aRaiseException then
        raise EIdWebSocketHandleError.Create(aFailedReason)
      else
        Exit;
    end;
    //check handshake key
    sResponseKey := Trim(sKey) +                                         //... "minus any leading and trailing whitespace"
                    '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';              //special GUID
    sResponseKey := TIdEncoderMIME.EncodeBytes(                          //Base64
                         FHash.HashString(sResponseKey) );               //SHA1
    if not SameText(Response.RawHeaders.Values['sec-websocket-accept'], sResponseKey) then
    begin
      aFailedReason := 'Invalid key handshake';
      if aRaiseException then
        raise EIdWebSocketHandleError.Create(aFailedReason)
      else
        Exit;
    end;
    end;

    //upgrade succesful
    IOHandlerWS.IsWebsocket := True;
    aFailedReason := '';
    Assert(Connected);

    if SocketIOCompatible then
    begin
      FSocketIOContext := TSocketIOContext.Create(Self);
      (FSocketIOContext as TSocketIOContext).ConnectSend := True;  //connect already send via url? GET /socket.io/1/websocket/9elrbEFqiimV29QAM6T-
      FSocketIO.WriteConnect(FSocketIOContext as TSocketIOContext);
    end;

    //always read the data! (e.g. RO use override of AsyncDispatchEvent to process data)
    //if Assigned(OnBinData) or Assigned(OnTextData) then
  finally
    Request.Clear;
    Request.CustomHeaders.Clear;
    strmResponse.Free;

    if bLocked and (IOHandler <> nil) then
      IOHandlerWS.Unlock;
    Unlock;

    //add to thread for auto retry/reconnect
    if not Self.NoAsyncRead then
      TIdWebsocketMultiReadThread.Instance.AddClient(Self);
  end;

  //default 2s write timeout
  //http://msdn.microsoft.com/en-us/library/windows/desktop/ms740532(v=vs.85).aspx
  if Connected then
    Self.IOHandler.Binding.SetSockOpt(SOL_SOCKET, SO_SNDTIMEO, Self.WriteTimeout);
end;

procedure TIdHTTPWebsocketClient.Lock;
begin
  System.TMonitor.Enter(Self);
end;

function TIdHTTPWebsocketClient.MakeImplicitClientHandler: TIdIOHandler;
begin
  if UseSSL then
  begin
    Result := TIdIOHandlerWebsocketSSL.Create(nil);
    FWebsocketImpl := (Result as TIdIOHandlerWebsocketSSL).WebsocketImpl;
  end
  else
  begin
    Result := TIdIOHandlerWebsocketPlain.Create(nil);
    FWebsocketImpl := (Result as TIdIOHandlerWebsocketPlain).WebsocketImpl;
  end;

  (Result as TIdIOHandlerStack).UseNagle := False;
end;

procedure TIdHTTPWebsocketClient.Ping;
var
  ws: TWebsocketImplementationProxy;
begin
  if TryLock then
  try
    ws  := IOHandlerWS;
    ws.LastPingTime := Now;

    //socket.io?
    if SocketIOCompatible and ws.IsWebsocket then
    begin
      FSocketIO.Lock;
      try
        if (FSocketIOContext <> nil) then
          FSocketIO.WritePing(FSocketIOContext as TSocketIOContext);  //heartbeat socket.io message
      finally
        FSocketIO.UnLock;
      end
    end
    //only websocket?
    else if not SocketIOCompatible and ws.IsWebsocket then
    begin
      if ws.TryLock then
      try
        ws.WriteData(nil, wdcPing);
      finally
        ws.Unlock;
      end;
    end;
  finally
    Unlock;
  end;
end;

procedure TIdHTTPWebsocketClient.ReadAndProcessData;
var
  strmEvent: TMemoryStream;
  swstext: utf8string;
  wscode: TWSDataCode;
begin
  strmEvent := nil;
  IOHandlerWS.Lock;
  try
    //try to process all events
    while IOHandlerWS.HasData or
          (IOHandler.Connected and
           IOHandler.Readable(0)) do     //has some data
    begin
      if strmEvent = nil then
        strmEvent := TMemoryStream.Create;
      strmEvent.Clear;

      //first is the data type TWSDataType(text or bin), but is ignore/not needed
      wscode := TWSDataCode(IOHandler.ReadLongWord);
      if not (wscode in [wdcText, wdcBinary, wdcPing, wdcPong]) then
      begin
        //Sleep(0);
        Continue;
      end;

      //next the size + data = stream
      IOHandler.ReadStream(strmEvent);

      //ignore ping/pong messages
      if wscode in [wdcPing, wdcPong] then Continue;

      //fire event
      //offload event dispatching to different thread! otherwise deadlocks possible? (do to synchronize)
      strmEvent.Position := 0;
      if wscode = wdcBinary then
      begin
        AsyncDispatchEvent(strmEvent);
      end
      else if wscode = wdcText then
      begin
        SetLength(swstext, strmEvent.Size);
        strmEvent.Read(swstext[1], strmEvent.Size);
        if swstext <> '' then
        begin
          AsyncDispatchEvent(string(swstext));
        end;
      end;
    end;
  finally
    IOHandlerWS.Unlock;
    strmEvent.Free;
  end;
end;

procedure TIdHTTPWebsocketClient.ResetChannel;
//var
//  ws: TIdIOHandlerWebsocket;
begin
//  TIdWebsocketMultiReadThread.Instance.RemoveClient(Self); keep for reconnect

  if IOHandler <> nil then
  begin
    IOHandler.InputBuffer.Clear;
    IOHandlerWS.BusyUpgrading := False;
    IOHandlerWS.IsWebsocket   := False;
    //close/disconnect internal socket
    //ws := IndyClient.IOHandler as TIdIOHandlerWebsocket;
    //ws.Close;  done in disconnect below
  end;
  Disconnect(False);
end;

procedure TIdHTTPWebsocketClient.SetIOHandlerStack(const Value: TIdIOHandlerStack);
begin
  inherited IOHandler := Value;
end;

procedure TIdHTTPWebsocketClient.SetOnData(const Value: TWebsocketMsgBin);
begin
//  if not Assigned(Value) and not Assigned(FOnTextData) then
//    TIdWebsocketMultiReadThread.Instance.RemoveClient(Self);

  FOnData := Value;

//  if Assigned(Value) and
//     (Self.IOHandler as TIdIOHandlerWebsocket).IsWebsocket
//  then
//    TIdWebsocketMultiReadThread.Instance.AddClient(Self);
end;

procedure TIdHTTPWebsocketClient.SetOnTextData(const Value: TWebsocketMsgText);
begin
//  if not Assigned(Value) and not Assigned(FOnData) then
//    TIdWebsocketMultiReadThread.Instance.RemoveClient(Self);

  FOnTextData := Value;

//  if Assigned(Value) and
//     (Self.IOHandler as TIdIOHandlerWebsocket).IsWebsocket
//  then
//    TIdWebsocketMultiReadThread.Instance.AddClient(Self);
end;

procedure TIdHTTPWebsocketClient.SetWriteTimeout(const Value: Integer);
begin
  FWriteTimeout := Value;
  if Connected then
    Self.IOHandler.Binding.SetSockOpt(SOL_SOCKET, SO_SNDTIMEO, Self.WriteTimeout);
end;

{ TIdWebsocketMultiReadThread }

procedure TIdWebsocketMultiReadThread.AddClient(
  aChannel: TIdHTTPWebsocketClient);
var l: TList;
begin
  //Assert( (aChannel.IOHandler as TIdIOHandlerWebsocket).IsWebsocket, 'Channel is not a websocket');
  if Self = nil then Exit;
  if Self.Terminated then Exit;

  l := FChannels.LockList;
  try
    //already exists?
    if l.IndexOf(aChannel) >= 0 then Exit;

    Assert(l.Count < 64, 'Max 64 connections can be handled by one read thread!');  //due to restrictions of the "select" API
    l.Add(aChannel);

    //trigger the "select" wait
    BreakSelectWait;
  finally
    FChannels.UnlockList;
  end;
end;

procedure TIdWebsocketMultiReadThread.AfterConstruction;
begin
  inherited;

  ReadTimeout := 5000;

  FChannels := TThreadList.Create;
  FillChar(Freadset, SizeOf(Freadset), 0);
  FillChar(Fexceptionset, SizeOf(Fexceptionset), 0);

  InitSpecialEventSocket;
end;

procedure TIdWebsocketMultiReadThread.BreakSelectWait;
var
  //iResult: Integer;
  LAddr: TSockAddrIn6;
begin
  if FTempHandle = 0 then Exit;

  FillChar(LAddr, SizeOf(LAddr), 0);
  //Id_IPv4
  with PSOCKADDR(@LAddr)^ do
  begin
    sin_family := Id_PF_INET4;
    //dummy address and port
    (GStack as TIdStackBSDBase).TranslateStringToTInAddr('0.0.0.0', sin_addr, Id_IPv4);
    sin_port := htons(1);
  end;

  FPendingBreak := True;

  //connect to non-existing address to stop "select" from waiting
  //Note: this is some kind of "hack" because there is no nice way to stop it
  //The only(?) other possibility is to make a "socket pair" and send a byte to it,
  //but this requires a dynamic server socket (which can trigger a firewall
  //exception/question popup in WindowsXP+)
  //iResult :=
  IdWinsock2.connect(FTempHandle, PSOCKADDR(@LAddr), SIZE_TSOCKADDRIN);
  //non blocking socket, so will always result in "would block"!
//  if (iResult <> Id_SOCKET_ERROR) or
//     ( (GStack <> nil) and (GStack.WSGetLastError <> WSAEWOULDBLOCK) )
//  then
//    GStack.CheckForSocketError(iResult);
end;

destructor TIdWebsocketMultiReadThread.Destroy;
begin
  if FReconnectThread <> nil then
  begin
    FReconnectThread.Terminate;
    FReconnectThread.WaitFor;
    FReconnectThread.Free;
  end;

  if FReconnectlist <> nil then
    FReconnectlist.Free;

  IdWinsock2.closesocket(FTempHandle);
  FTempHandle := 0;
  FChannels.Free;
  inherited;
end;

procedure TIdWebsocketMultiReadThread.Execute;
begin
  Self.NameThreadForDebugging(AnsiString(Self.ClassName));

  while not Terminated do
  begin
    try
      while not Terminated do
      begin
        ReadFromAllChannels;
        PingAllChannels;
      end;
    except
      //continue
    end;
  end;
end;

procedure TIdWebsocketMultiReadThread.InitSpecialEventSocket;
var
  param: Cardinal;
  iResult: Integer;
begin
  if GStack = nil then Exit; //finalized?

  //alloc socket
  FTempHandle := GStack.NewSocketHandle(Id_SOCK_STREAM, Id_IPPROTO_IP, Id_IPv4, False);
  Assert(FTempHandle <> Id_INVALID_SOCKET);
  //non block mode
  param   := 1; // enable NON blocking mode
  iResult := ioctlsocket(FTempHandle, FIONBIO, param);
  GStack.CheckForSocketError(iResult);
end;

class function TIdWebsocketMultiReadThread.Instance: TIdWebsocketMultiReadThread;
begin
  if (FInstance = nil) then
  begin
    if GUnitFinalized then Exit(nil);

    FInstance := TIdWebsocketMultiReadThread.Create(True);
    FInstance.Start;
  end;
  Result := FInstance;
end;

procedure TIdWebsocketMultiReadThread.PingAllChannels;
var
  l: TList;
  chn: TIdHTTPWebsocketClient;
  ws: TWebsocketImplementationProxy;
  i: Integer;
begin
  if Terminated then Exit;

  l := FChannels.LockList;
  try
    for i := 0 to l.Count - 1 do
    begin
      chn := TIdHTTPWebsocketClient(l.Items[i]);
      if chn.NoAsyncRead then Continue;

      ws  := chn.IOHandlerWS;
      //valid?
      if (chn.IOHandler <> nil) and
         (chn.IOHandlerWS.IsWebsocket) and
         (chn.Socket <> nil) and
         (chn.Socket.Binding <> nil) and
         (chn.Socket.Binding.Handle > 0) and
         (chn.Socket.Binding.Handle <> INVALID_SOCKET) then
      begin
        //more than 10s nothing done? then send ping
        if SecondsBetween(Now, ws.LastPingTime) > 10 then
          if chn.CheckConnection then
          try
            chn.Ping;
          except
            //retry connect the next time?
          end;
      end
      else if not chn.Connected then
      begin
        if (ws <> nil) and
           (SecondsBetween(Now, ws.LastActivityTime) < 5)
        then
            Continue;

        if FReconnectlist = nil then
          FReconnectlist := TWSThreadList.Create;
        //if chn.TryLock then
        FReconnectlist.Add(chn);
      end;
    end;
  finally
    FChannels.UnlockList;
  end;

  if Terminated then Exit;

  //reconnect needed? (in background)
  if FReconnectlist <> nil then
  if FReconnectlist.Count > 0 then
  begin
    if FReconnectThread = nil then
      FReconnectThread := TIdWebsocketQueueThread.Create(False{direct start});
    FReconnectThread.QueueEvent(
      procedure
      var
        l: TList;
        chn: TIdHTTPWebsocketClient;
      begin
        while FReconnectlist.Count > 0 do
        begin
          chn := nil;
          try
            //get first one
            l := FReconnectlist.LockList;
            try
              if l.Count <= 0 then Exit;

              chn := TObject(l.Items[0]) as TIdHTTPWebsocketClient;
              if not chn.TryLock then
              begin
                l.Delete(0);
                chn := nil;
                Continue;
              end;
            finally
              FReconnectlist.UnlockList;
            end;

            //try reconnect
            ws := chn.IOHandlerWS;
            if ( (ws = nil) or
                 (SecondsBetween(Now, ws.LastActivityTime) >= 5) ) then
            begin
              try
                if not chn.Connected then
                begin
                  if ws <> nil then
                    ws.LastActivityTime := Now;
                  //chn.ConnectTimeout  := 1000;
                  if (chn.Host <> '') and (chn.Port > 0) then
                    chn.TryUpgradeToWebsocket;
                end;
              except
                //just try
              end;
            end;

            //remove from todo list
            l := FReconnectlist.LockList;
            try
              if l.Count > 0 then
                l.Delete(0);
            finally
              FReconnectlist.UnlockList;
            end;
          finally
            if chn <> nil then
              chn.Unlock;
          end;
        end;
      end);
  end;
end;

procedure TIdWebsocketMultiReadThread.ReadFromAllChannels;
var
  l: TList;
  chn: TIdHTTPWebsocketClient;
  iCount,
  i: Integer;
  iResult: NativeInt;
  ws: TWebsocketImplementationProxy;
begin
  l := FChannels.LockList;
  try
    iCount  := 0;
    iResult := 0;
    Freadset.fd_count := iCount;

    for i := 0 to l.Count - 1 do
    begin
      chn := TIdHTTPWebsocketClient(l.Items[i]);
      if chn.NoAsyncRead then Continue;

      //valid?
      if //not chn.Busy and    also take busy channels (will be ignored later), otherwise we have to break/reset for each RO function execution
         (chn.IOHandler <> nil) and
         (chn.IOHandlerWS.IsWebsocket) and
         (chn.Socket <> nil) and
         (chn.Socket.Binding <> nil) and
         (chn.Socket.Binding.Handle > 0) and
         (chn.Socket.Binding.Handle <> INVALID_SOCKET) then
      begin
        if chn.IOHandlerWS.HasData then
        begin
          Inc(iResult);
          Break;
        end;

        Freadset.fd_count         := iCount+1;
        Freadset.fd_array[iCount] := chn.Socket.Binding.Handle;
        Inc(iCount);
      end;
    end;

    if FPendingBreak then
      ResetSpecialEventSocket;
  finally
    FChannels.UnlockList;
  end;

  //special helper socket to be able to stop "select" from waiting
  Fexceptionset.fd_count    := 1;
  Fexceptionset.fd_array[0] := FTempHandle;

  //wait 15s till some data
  Finterval.tv_sec  := Self.ReadTimeout div 1000; //5s
  Finterval.tv_usec := Self.ReadTimeout mod 1000;

  //nothing to wait for? then sleep some time to prevent 100% CPU
  if iResult = 0 then
  begin
    if iCount = 0 then
    begin
      iResult := IdWinsock2.select(0, nil, nil, @Fexceptionset, @Finterval);
      if iResult = SOCKET_ERROR then
        iResult := 1;  //ignore errors
    end
    //wait till a socket has some data (or a signal via exceptionset is fired)
    else
      iResult := IdWinsock2.select(0, @Freadset, nil, @Fexceptionset, @Finterval);
    if iResult = SOCKET_ERROR then
      //raise EIdWinsockStubError.Build(WSAGetLastError, '', []);
      //ignore error during wait: socket disconnected etc
      Exit;
  end;

  if Terminated then Exit;

  //some data?
  if (iResult > 0) then
  begin
    //make sure the thread is created outside a lock
    TIdWebsocketDispatchThread.Instance;

    l := FChannels.LockList;
    if l = nil then Exit;
    try
      //check for data for all channels
      for i := 0 to l.Count - 1 do
      begin
        chn := TIdHTTPWebsocketClient(l.Items[i]);
        if chn.NoAsyncRead then Continue;

        if chn.TryLock then
        try
          ws  := chn.IOHandlerWS;
          if (ws = nil) then Continue;

          if ws.TryLock then     //IOHandler.Readable cannot be done during pending action!
          try
            try
              chn.ReadAndProcessData;
            except
              on e:Exception do
              begin
                l := nil;
                FChannels.UnlockList;
                chn.ResetChannel;
                //raise;
              end;
            end;
          finally
            ws.Unlock;
          end;
        finally
          chn.Unlock;
        end;
      end;

      if FPendingBreak then
        ResetSpecialEventSocket;
    finally
      if l <> nil then
        FChannels.UnlockList;
      //strmEvent.Free;
    end;
  end;
end;

procedure TIdWebsocketMultiReadThread.RemoveClient(
  aChannel: TIdHTTPWebsocketClient);
begin
  if Self = nil then Exit;
  if Self.Terminated then Exit;

  aChannel.Lock;
  try
    FChannels.Remove(aChannel);
    if FReconnectlist <> nil then
      FReconnectlist.Remove(aChannel);
  finally
    aChannel.UnLock;
  end;
  BreakSelectWait;
end;

class procedure TIdWebsocketMultiReadThread.RemoveInstance(aForced: boolean);
var
  o: TIdWebsocketMultiReadThread;
begin
  if FInstance <> nil then
  begin
    FInstance.Terminate;
    o := FInstance;
    FInstance := nil;

    if aForced then
    begin
      WaitForSingleObject(o.Handle, 2 * 1000);
      TerminateThread(o.Handle, MaxInt);
    end
    else
      o.WaitFor;
    FreeAndNil(o);
  end;
end;

procedure TIdWebsocketMultiReadThread.ResetSpecialEventSocket;
begin
  Assert(FPendingBreak);
  FPendingBreak := False;

  IdWinsock2.closesocket(FTempHandle);
  FTempHandle := 0;
  InitSpecialEventSocket;
end;

procedure TIdWebsocketMultiReadThread.Terminate;
begin
  inherited Terminate;
  if FReconnectThread <> nil then
    FReconnectThread.Terminate;

  FChannels.LockList;
  try
    //fire a signal, so the "select" wait will quit and thread can stop
    BreakSelectWait;
  finally
    FChannels.UnlockList;
  end;
end;

{ TIdWebsocketDispatchThread }

class function TIdWebsocketDispatchThread.Instance: TIdWebsocketDispatchThread;
begin
  if FInstance = nil then
  begin
    if GUnitFinalized then Exit(nil);

    GlobalNameSpace.BeginWrite;
    try
      if FInstance = nil then
      begin
        FInstance := Self.Create(True);
        FInstance.Start;
      end;
    finally
      GlobalNameSpace.EndWrite;
    end;
  end;
  Result := FInstance;
end;

class procedure TIdWebsocketDispatchThread.RemoveInstance;
var
  o: TIdWebsocketDispatchThread;
begin
  if FInstance <> nil then
  begin
    FInstance.Terminate;
    o := FInstance;
    FInstance := nil;

    if aForced then
    begin
      WaitForSingleObject(o.Handle, 2 * 1000);
      TerminateThread(o.Handle, MaxInt);
    end;
    o.WaitFor;
    FreeAndNil(o);
  end;
end;

{ TWSThreadList }

function TWSThreadList.Count: Integer;
var l: TList;
begin
  l := LockList;
  try
    Result := l.Count;
  finally
    UnlockList;
  end;
end;

initialization
finalization
  GUnitFinalized := True;
  if TIdWebsocketMultiReadThread.Instance <> nil then
    TIdWebsocketMultiReadThread.Instance.Terminate;
  TIdWebsocketDispatchThread.RemoveInstance();
  TIdWebsocketMultiReadThread.RemoveInstance();
end.
