{ Demo: replays the recorded device streams in data/ through the gateway and
  prints observations, alarm transitions, HL7 messages and parser statistics.

  Usage: bedsidelink [--data DIR] [--hl7 all|first|none] [--quiet] }
program BedsideLink;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, IniFiles, DateUtils, ObsModel, DeviceDriver, DrvMonitor,
  DrvVentilator, DrvInfusion, Transport, AlarmEngine, HL7Encoder, Gateway;

type
  THL7Mode = (hmAll, hmFirst, hmNone);

  TDemo = class
  private
    FHL7Mode: THL7Mode;
    FQuiet: Boolean;
    FHL7Shown: string;  // device ids whose first message was printed
    FAlarmCount: Integer;
  public
    procedure OnBatch(Sender: TObject; const Batch: TObservationBatch;
      const Alarms: TAlarmEvents; const Message: string);
    property HL7Mode: THL7Mode read FHL7Mode write FHL7Mode;
    property Quiet: Boolean read FQuiet write FQuiet;
    property AlarmCount: Integer read FAlarmCount;
  end;

function QualityMark(Q: TQuality): string;
begin
  case Q of
    qQuestionable: Result := '?';
    qInvalid: Result := '!';
  else
    Result := '';
  end;
end;

procedure TDemo.OnBatch(Sender: TObject; const Batch: TObservationBatch;
  const Alarms: TAlarmEvents; const Message: string);
var
  Line, Seg: string;
  Obs: TObservation;
  E: TAlarmEvent;
begin
  if not FQuiet then
  begin
    Line := Format('%s %-6s %-9s #%-3d', [FormatDateTime('hh:nn:ss', Batch.Timestamp),
      Batch.BedId, Batch.DeviceId, Batch.Sequence]);
    for Obs in Batch.Observations do
      if Obs.Quality = qInvalid then
        Line := Line + ' ' + Obs.Code + '=---'
      else
        Line := Line + ' ' + Obs.Code + '=' + FormatObsValue(Obs) + QualityMark(Obs.Quality);
    WriteLn(Line);
  end;
  for E in Alarms do
  begin
    WriteLn('  ALARM ', FormatAlarmEvent(E));
    Inc(FAlarmCount);
  end;
  if (FHL7Mode = hmAll) or ((FHL7Mode = hmFirst) and
     (Pos('|' + Batch.DeviceId + '|', FHL7Shown) = 0)) then
  begin
    FHL7Shown := FHL7Shown + '|' + Batch.DeviceId + '|';
    WriteLn('  --- HL7 v2.5 ORU^R01 ---');
    for Seg in HL7Segments(Message) do
      WriteLn('  ', Seg);
  end;
end;

procedure Usage;
begin
  WriteLn('usage: bedsidelink [--data DIR] [--hl7 all|first|none] [--quiet]');
  WriteLn('  --hl7 first  print the first HL7 message of each device (default)');
  Halt(2);
end;

var
  DataDir, Arg: string;
  I: Integer;
  Demo: TDemo;
  GW: TGateway;
  Ini: TMemIniFile;
  Opts: THL7Options;
  Ch: TChannel;
  A: TActiveAlarm;
  TotalErrors: Int64;
begin
  DataDir := 'data';
  Demo := TDemo.Create;
  Demo.HL7Mode := hmFirst;
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '--data') and (I < ParamCount) then
    begin
      Inc(I);
      DataDir := ParamStr(I);
    end
    else if (Arg = '--hl7') and (I < ParamCount) then
    begin
      Inc(I);
      case LowerCase(ParamStr(I)) of
        'all': Demo.HL7Mode := hmAll;
        'first': Demo.HL7Mode := hmFirst;
        'none': Demo.HL7Mode := hmNone;
      else
        Usage;
      end;
    end
    else if Arg = '--quiet' then
      Demo.Quiet := True
    else
      Usage;
    Inc(I);
  end;

  WriteLn('bedside-link demo. Not a medical device. For engineering demonstration only.');
  Ini := TMemIniFile.Create(ConcatPaths([DataDir, 'devices.ini']));
  Opts := DefaultHL7Options;
  Opts.PointOfCare := Ini.ReadString('gateway', 'PointOfCare', Opts.PointOfCare);
  GW := TGateway.Create(Opts);
  try
    try
      GW.Clock := EncodeDateTime(2026, 10, 20, 9, 0, 0, 0);
      GW.Alarms.LoadFromFile(ConcatPaths([DataDir,
        Ini.ReadString('gateway', 'AlarmConfig', 'alarms.ini')]));
      GW.LoadDevices(Ini, DataDir);
      GW.OnBatch := @Demo.OnBatch;

      WriteLn(Format('%d alarm rules, %d channels', [GW.Alarms.RuleCount, GW.ChannelCount]));
      for I := 0 to GW.ChannelCount - 1 do
      begin
        Ch := GW.Channels[I];
        WriteLn(Format('  %-9s %-6s %s <- %s', [Ch.Driver.DeviceId, Ch.Driver.BedId,
          Ch.Driver.Description, Ch.Transport.Name]));
      end;
      WriteLn;

      GW.RunUntilEof;

      WriteLn;
      WriteLn('Parser statistics');
      TotalErrors := 0;
      for I := 0 to GW.ChannelCount - 1 do
      begin
        Ch := GW.Channels[I];
        WriteLn(Format('  %-9s %s', [Ch.Driver.DeviceId, Ch.Driver.StatsSummary]));
        with Ch.Driver.Stats do
          Inc(TotalErrors, ChecksumErrors + FramingErrors + ContentErrors);
      end;
      WriteLn('Alarms still displayed');
      for A in GW.Alarms.ActiveAlarms do
        WriteLn(Format('  %-6s %-8s %-4s %-6s %s', [A.BedId, A.Code,
          ConditionNames[A.Condition], PriorityNames[A.Priority], StateNames[A.State]]));
      WriteLn(Format('Summary: %d HL7 messages, %d alarm transitions, %d frames rejected',
        [GW.MessagesEncoded, Demo.AlarmCount, TotalErrors]));
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'error: ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    GW.Free;
    Ini.Free;
    Demo.Free;
  end;
end.
