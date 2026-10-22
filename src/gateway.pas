{ Gateway: wires transports to drivers and drivers to the alarm engine and
  the HL7 encoder. Each channel owns one transport and one driver. The pump
  loop round-robins over channels with a small read buffer, so one chatty
  device cannot starve the others and a stalled device costs nothing. }
unit Gateway;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, IniFiles, ObsModel, DeviceDriver, Transport, AlarmEngine,
  HL7Encoder;

type
  TGatewayBatchEvent = procedure(Sender: TObject; const Batch: TObservationBatch;
    const Alarms: TAlarmEvents; const Message: string) of object;

  TChannel = class
  private
    FTransport: TTransport;
    FDriver: TDeviceDriver;
  public
    constructor Create(ATransport: TTransport; ADriver: TDeviceDriver);
    destructor Destroy; override;
    property Transport: TTransport read FTransport;
    property Driver: TDeviceDriver read FDriver;
  end;

  TGateway = class
  private
    FChannels: TList;
    FAlarms: TAlarmEngine;
    FEncoder: THL7Encoder;
    FClock: TDateTime;
    FOnBatch: TGatewayBatchEvent;
    FMessages: Integer;
    function GetChannel(I: Integer): TChannel;
    function GetChannelCount: Integer;
    procedure DriverBatch(Sender: TObject; const Batch: TObservationBatch);
  public
    constructor Create(const Options: THL7Options);
    destructor Destroy; override;
    function AddChannel(ATransport: TTransport; ADriver: TDeviceDriver): TChannel;
    { Reads [device.*] sections: Kind, Bed, Replay (path relative to BaseDir),
      MaxChunk, Seed. Replay is the only transport the demo needs; a serial
      section would carry Port and Baud instead. }
    procedure LoadDevices(Ini: TCustomIniFile; const BaseDir: string);
    { One round over every channel. Returns the number of bytes moved. }
    function PumpOnce(BufSize: Integer = 16): Integer;
    procedure RunUntilEof;
    function AllEof: Boolean;
    property Alarms: TAlarmEngine read FAlarms;
    property Encoder: THL7Encoder read FEncoder;
    property Channels[I: Integer]: TChannel read GetChannel;
    property ChannelCount: Integer read GetChannelCount;
    property MessagesEncoded: Integer read FMessages;
    { Clock used for MSH-7. Fixed by the demo and tests for reproducible output. }
    property Clock: TDateTime read FClock write FClock;
    property OnBatch: TGatewayBatchEvent read FOnBatch write FOnBatch;
  end;

implementation

{ TChannel }

constructor TChannel.Create(ATransport: TTransport; ADriver: TDeviceDriver);
begin
  inherited Create;
  FTransport := ATransport;
  FDriver := ADriver;
end;

destructor TChannel.Destroy;
begin
  FDriver.Free;
  FTransport.Free;
  inherited Destroy;
end;

{ TGateway }

constructor TGateway.Create(const Options: THL7Options);
begin
  inherited Create;
  FChannels := TList.Create;
  FAlarms := TAlarmEngine.Create;
  FEncoder := THL7Encoder.Create(Options);
  FClock := Now;
end;

destructor TGateway.Destroy;
var
  I: Integer;
begin
  for I := 0 to FChannels.Count - 1 do
    TChannel(FChannels[I]).Free;
  FChannels.Free;
  FEncoder.Free;
  FAlarms.Free;
  inherited Destroy;
end;

function TGateway.GetChannel(I: Integer): TChannel;
begin
  Result := TChannel(FChannels[I]);
end;

function TGateway.GetChannelCount: Integer;
begin
  Result := FChannels.Count;
end;

function TGateway.AddChannel(ATransport: TTransport; ADriver: TDeviceDriver): TChannel;
begin
  ADriver.OnBatch := @DriverBatch;
  Result := TChannel.Create(ATransport, ADriver);
  FChannels.Add(Result);
end;

procedure TGateway.LoadDevices(Ini: TCustomIniFile; const BaseDir: string);
var
  Sections: TStringList;
  Section, DevId, Kind, Bed, Replay: string;
  Drv: TDeviceDriver;
  Tr: TTransport;
begin
  Sections := TStringList.Create;
  try
    Ini.ReadSections(Sections);
    for Section in Sections do
    begin
      if Pos('device.', LowerCase(Section)) <> 1 then
        Continue;
      DevId := Copy(Section, 8, MaxInt);
      Kind := Ini.ReadString(Section, 'Kind', '');
      Bed := Ini.ReadString(Section, 'Bed', '');
      Replay := Ini.ReadString(Section, 'Replay', '');
      if (Kind = '') or (Bed = '') or (Replay = '') then
        raise EDriverError.CreateFmt('[%s] needs Kind, Bed and Replay', [Section]);
      Drv := CreateDriver(Kind, DevId, Bed);
      try
        Tr := TReplayTransport.CreateFromFile(
          ConcatPaths([BaseDir, Replay]),
          Ini.ReadInteger(Section, 'MaxChunk', 7),
          Ini.ReadInteger(Section, 'Seed', 1));
      except
        Drv.Free;
        raise;
      end;
      AddChannel(Tr, Drv);
    end;
  finally
    Sections.Free;
  end;
end;

procedure TGateway.DriverBatch(Sender: TObject; const Batch: TObservationBatch);
var
  Events: TAlarmEvents;
  Msg: string;
begin
  // Evaluate first so the HL7 message carries abnormal flags for this sample.
  Events := FAlarms.Process(Batch);
  Msg := FEncoder.Encode(Batch, FClock, FAlarms.AbnormalFlags(Batch.BedId));
  Inc(FMessages);
  if Assigned(FOnBatch) then
    FOnBatch(Self, Batch, Events, Msg);
end;

function TGateway.PumpOnce(BufSize: Integer): Integer;
var
  I, N: Integer;
  Buf: array of Byte;
  Ch: TChannel;
begin
  Result := 0;
  Buf := nil;
  SetLength(Buf, BufSize);
  for I := 0 to FChannels.Count - 1 do
  begin
    Ch := TChannel(FChannels[I]);
    if Ch.Transport.Eof then
      Continue;
    N := Ch.Transport.Read(Buf[0], BufSize);
    if N > 0 then
    begin
      Ch.Driver.Feed(Buf[0], N);
      Inc(Result, N);
    end;
  end;
end;

function TGateway.AllEof: Boolean;
var
  I: Integer;
begin
  for I := 0 to FChannels.Count - 1 do
    if not TChannel(FChannels[I]).Transport.Eof then
      Exit(False);
  Result := True;
end;

procedure TGateway.RunUntilEof;
begin
  while not AllEof do
    PumpOnce;
end;

end.
