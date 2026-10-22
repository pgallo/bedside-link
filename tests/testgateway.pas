{ End-to-end: the recorded streams in data/ through transports, drivers,
  alarm engine and HL7 encoder, exactly as the demo wires them. }
unit TestGateway;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, IniFiles, fpcunit, testregistry, ObsModel, DeviceDriver,
  DrvMonitor, DrvVentilator, DrvInfusion, Transport, AlarmEngine, HL7Encoder,
  Gateway, TestHelpers;

type
  TGatewayTests = class(TTestCase)
  private
    FGW: TGateway;
    FMessages: TStringList;
    FEvents: array of TAlarmEvent;
    procedure OnBatch(Sender: TObject; const Batch: TObservationBatch;
      const Alarms: TAlarmEvents; const Message: string);
    function CountEvents(const Code: string; T: TAlarmTransition): Integer;
    function CountCond(const Code: string; C: TAlarmCondition; T: TAlarmTransition): Integer;
    procedure LoadAndRun(BufSize: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ReplaysAllRecordedStreams;
    procedure RejectedFramesMatchInjectedFaults;
    procedure ClinicalEpisodeProducesExpectedAlarms;
    procedure EveryMessageIsWellFormedHL7;
    procedure ResultIndependentOfReadSize;
  end;

implementation

procedure TGatewayTests.SetUp;
begin
  FGW := TGateway.Create(DefaultHL7Options);
  FMessages := TStringList.Create;
  FEvents := nil;
end;

procedure TGatewayTests.TearDown;
begin
  FMessages.Free;
  FGW.Free;
end;

procedure TGatewayTests.OnBatch(Sender: TObject; const Batch: TObservationBatch;
  const Alarms: TAlarmEvents; const Message: string);
var
  E: TAlarmEvent;
  N: Integer;
begin
  // Stored with segments joined by LF so a failing comparison is readable.
  FMessages.Add(StringReplace(Message, #13, #10, [rfReplaceAll]));
  for E in Alarms do
  begin
    N := Length(FEvents);
    SetLength(FEvents, N + 1);
    FEvents[N] := E;
  end;
end;

function TGatewayTests.CountEvents(const Code: string; T: TAlarmTransition): Integer;
var
  E: TAlarmEvent;
begin
  Result := 0;
  for E in FEvents do
    if (E.Code = Code) and (E.Transition = T) then
      Inc(Result);
end;

function TGatewayTests.CountCond(const Code: string; C: TAlarmCondition;
  T: TAlarmTransition): Integer;
var
  E: TAlarmEvent;
begin
  Result := 0;
  for E in FEvents do
    if (E.Code = Code) and (E.Condition = C) and (E.Transition = T) then
      Inc(Result);
end;

procedure TGatewayTests.LoadAndRun(BufSize: Integer);
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(ConcatPaths([TestDataDir, 'devices.ini']));
  try
    FGW.Alarms.LoadFromFile(ConcatPaths([TestDataDir, 'alarms.ini']));
    FGW.LoadDevices(Ini, TestDataDir);
  finally
    Ini.Free;
  end;
  FGW.OnBatch := @OnBatch;
  FGW.Clock := T0;
  while not FGW.AllEof do
    FGW.PumpOnce(BufSize);
end;

procedure TGatewayTests.ReplaysAllRecordedStreams;
begin
  LoadAndRun(16);
  AssertEquals(3, FGW.ChannelCount);
  AssertEquals(33, FGW.Channels[0].Driver.Stats.FramesOk);  // monitor: 36 sent, 3 corrupted
  AssertEquals(33, FGW.Channels[1].Driver.Stats.FramesOk);  // ventilator: 36 sent, 3 corrupted
  AssertEquals(10, FGW.Channels[2].Driver.Stats.FramesOk);  // pump: 12 sent, 2 corrupted
  AssertEquals(76, FGW.MessagesEncoded);
end;

procedure TGatewayTests.RejectedFramesMatchInjectedFaults;

  procedure Check(I: Integer; Crc, Framing, Lost: Integer);
  var
    D: TDeviceDriver;
  begin
    D := FGW.Channels[I].Driver;
    AssertEquals(D.DeviceId + ' checksum errors', Crc, D.Stats.ChecksumErrors);
    AssertEquals(D.DeviceId + ' framing errors', Framing, D.Stats.FramingErrors);
    AssertEquals(D.DeviceId + ' frames lost', Lost, D.Stats.FramesLost);
    AssertEquals(D.DeviceId + ' content errors', 0, D.Stats.ContentErrors);
  end;

begin
  LoadAndRun(16);
  // See tools/gensamples.pas for the faults injected into each stream.
  // Monitor: bad checksum, lost ETX, non-hex checksum.
  Check(0, 1, 2, 3);
  // Ventilator: payload bit flip and wrong LEN (CRC), LEN beyond maximum and
  // an impossible-LEN noise burst (framing; the burst is not a frame).
  Check(1, 2, 2, 3);
  // Pump: bad checksum, missing checksum, runaway line (not a sequenced record).
  Check(2, 1, 2, 2);
end;

procedure TGatewayTests.ClinicalEpisodeProducesExpectedAlarms;
begin
  LoadAndRun(16);
  AssertEquals('HR high raised once', 1, CountCond('HR', acHigh, atRaised));
  AssertEquals('HR high cleared once', 1, CountCond('HR', acHigh, atCleared));
  AssertEquals('HR rate episodes', 2, CountCond('HR', acRate, atRaised));
  AssertEquals('SPO2 low raised once despite oscillation', 1, CountEvents('SPO2', atRaised));
  AssertEquals('SPO2 latched', 1, CountEvents('SPO2', atLatched));
  AssertEquals('PIP raised', 1, CountEvents('PIP', atRaised));
  AssertEquals('occlusion raised', 1, CountEvents('INF_OCCL', atRaised));
  AssertEquals('occlusion latched', 1, CountEvents('INF_OCCL', atLatched));
  AssertEquals('latched alarms still displayed', 3, Length(FGW.Alarms.ActiveAlarms));
end;

procedure TGatewayTests.EveryMessageIsWellFormedHL7;
var
  Msg, Seg: string;
  Segs: TStringArray;
begin
  LoadAndRun(16);
  AssertEquals(76, FMessages.Count);
  for Msg in FMessages do
  begin
    // OnBatch stored the message with CR replaced by LF; a raw LF inside a
    // field would show up here as an extra, malformed segment.
    Segs := HL7Segments(StringReplace(Msg, #10, #13, [rfReplaceAll]));
    AssertTrue(Length(Segs) >= 5);
    AssertEquals('MSH|^~\&|', Copy(Segs[0], 1, 9));
    for Seg in Segs do
      AssertTrue('segment id ' + Seg, (Length(Seg) > 4) and (Seg[4] = '|') and
        (Pos(Copy(Seg, 1, 3), 'MSH PID PV1 OBR OBX') > 0));
  end;
end;

procedure TGatewayTests.ResultIndependentOfReadSize;

  // The interleaving of devices, and therefore MSH-10 control ids, depends
  // on read size. Everything below MSH must not.
  function Bodies: TStringList;
  var
    I: Integer;
  begin
    Result := TStringList.Create;
    for I := 0 to FMessages.Count - 1 do
      Result.Add(Copy(FMessages[I], Pos(#10, FMessages[I]) + 1, MaxInt));
    Result.Sort;
  end;

var
  Ref, Got: TStringList;
begin
  LoadAndRun(16);
  Ref := Bodies;
  try
    FGW.Free;
    FMessages.Clear;
    FGW := TGateway.Create(DefaultHL7Options);
    LoadAndRun(1);
    Got := Bodies;
    try
      AssertEquals(Ref.Count, Got.Count);
      AssertTrue('decoded content differs', Ref.Equals(Got));
    finally
      Got.Free;
    end;
  finally
    Ref.Free;
  end;
end;

initialization
  RegisterTest(TGatewayTests);
end.
