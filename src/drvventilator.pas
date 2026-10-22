{ Simulated ventilator protocol: binary, length-prefixed, CRC-16/CCITT.

    offset  size  field
    0       1     SYNC1  $A5
    1       1     SYNC2  $5A
    2       1     LEN    payload length (5..VentMaxPayload)
    3       LEN   payload
    3+LEN   2     CRC-16/CCITT-FALSE over LEN and payload, big-endian

  Payload:
    0  1  message type ($01 measurement, $02 heartbeat)
    1  2  sequence number, uint16 big-endian
    3  4  device time, uint32 big-endian, seconds since 2000-01-01 00:00:00
    7  1  item count N (measurement only)
    8  4N items: param id (1), value int16 big-endian (2), flags (1)

  Values are fixed point; the scale is per parameter (see VentParams).
  Flags: bit0 invalid, bit1 questionable.

  Unlike the ASCII protocols this one cannot rely on a delimiter, so the
  parser buffers bytes and rescans from SYNC1+1 whenever a frame fails its
  CRC. Skipping the whole claimed length instead would let a single corrupted
  LEN byte swallow the valid frames that follow it. }
unit DrvVentilator;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ObsModel, DeviceDriver;

const
  VentSync1 = $A5;
  VentSync2 = $5A;
  VentMaxPayload = 8 + 4 * 16;
  VentMsgMeasurement = $01;
  VentMsgHeartbeat = $02;
  VentFlagInvalid = $01;
  VentFlagQuestionable = $02;

type
  TVentParam = record
    Id: Byte;
    Code: string;
    Scale: Integer;  // raw value = engineering value * Scale
  end;

  TVentItem = record
    Id: Byte;
    Value: Double;
    Flags: Byte;
  end;
  TVentItemArray = array of TVentItem;

  TVentilatorDriver = class(TDeviceDriver)
  private
    FBuf: TBytes;
    FLen: Integer;
    procedure Scan;
    procedure Consume(Count: Integer);
    procedure HandlePayload(Start, Len: Integer);
  protected
    procedure ProcessByte(B: Byte); override;
  public
    class function Kind: string; override;
    class function Description: string; override;
    procedure Reset; override;
    class function EncodeMeasurement(Seq: Word; Time: TDateTime;
      const Items: TVentItemArray): AnsiString;
    class function EncodeHeartbeat(Seq: Word; Time: TDateTime): AnsiString;
  end;

const
  VentParams: array[0..5] of TVentParam = (
    (Id: 1; Code: 'PIP';  Scale: 10),
    (Id: 2; Code: 'PEEP'; Scale: 10),
    (Id: 3; Code: 'VRR';  Scale: 1),
    (Id: 4; Code: 'VT';   Scale: 1),
    (Id: 5; Code: 'FIO2'; Scale: 1),
    (Id: 6; Code: 'MV';   Scale: 100)
  );

function FindVentParam(Id: Byte; out P: TVentParam): Boolean;
function VentEpoch: TDateTime;

implementation

uses
  DateUtils, Checksums;

function VentEpoch: TDateTime;
begin
  Result := EncodeDateTime(2000, 1, 1, 0, 0, 0, 0);
end;

function FindVentParam(Id: Byte; out P: TVentParam): Boolean;
var
  I: Integer;
begin
  for I := Low(VentParams) to High(VentParams) do
    if VentParams[I].Id = Id then
    begin
      P := VentParams[I];
      Exit(True);
    end;
  Result := False;
end;

function BE16(Value: Word): AnsiString;
begin
  Result := AnsiChar(Value shr 8) + AnsiChar(Value and $FF);
end;

function BE32(Value: Cardinal): AnsiString;
begin
  Result := BE16(Word(Value shr 16)) + BE16(Word(Value and $FFFF));
end;

function WrapFrame(const Payload: AnsiString): AnsiString;
var
  Body: AnsiString;
begin
  Body := AnsiChar(Length(Payload)) + Payload;
  Result := AnsiChar(VentSync1) + AnsiChar(VentSync2) + Body + BE16(Crc16CcittStr(Body));
end;

function DeviceSeconds(Time: TDateTime): Cardinal;
begin
  Result := Cardinal(SecondsBetween(Time, VentEpoch));
end;

class function TVentilatorDriver.EncodeMeasurement(Seq: Word; Time: TDateTime;
  const Items: TVentItemArray): AnsiString;
var
  Payload: AnsiString;
  It: TVentItem;
  P: TVentParam;
  Raw: SmallInt;
begin
  Payload := AnsiChar(VentMsgMeasurement) + BE16(Seq) + BE32(DeviceSeconds(Time)) +
    AnsiChar(Length(Items));
  for It in Items do
  begin
    if not FindVentParam(It.Id, P) then
      P.Scale := 1;
    Raw := SmallInt(Round(It.Value * P.Scale));
    Payload := Payload + AnsiChar(It.Id) + BE16(Word(Raw)) + AnsiChar(It.Flags);
  end;
  Result := WrapFrame(Payload);
end;

class function TVentilatorDriver.EncodeHeartbeat(Seq: Word; Time: TDateTime): AnsiString;
begin
  Result := WrapFrame(AnsiChar(VentMsgHeartbeat) + BE16(Seq) + BE32(DeviceSeconds(Time)));
end;

class function TVentilatorDriver.Kind: string;
begin
  Result := 'ventilator';
end;

class function TVentilatorDriver.Description: string;
begin
  Result := 'Ventilator, binary length-prefixed frames with CRC-16/CCITT';
end;

procedure TVentilatorDriver.Reset;
begin
  Discard(FLen);
  FLen := 0;
end;

procedure TVentilatorDriver.ProcessByte(B: Byte);
begin
  if FLen >= Length(FBuf) then
    SetLength(FBuf, Length(FBuf) * 2 + 64);
  FBuf[FLen] := B;
  Inc(FLen);
  Scan;
end;

procedure TVentilatorDriver.Consume(Count: Integer);
begin
  if Count >= FLen then
    FLen := 0
  else
  begin
    Move(FBuf[Count], FBuf[0], FLen - Count);
    Dec(FLen, Count);
  end;
end;

procedure TVentilatorDriver.Scan;
var
  PayLen, FrameLen: Integer;
  Crc, Got: Word;
begin
  while FLen > 0 do
  begin
    if FBuf[0] <> VentSync1 then
    begin
      Discard;
      Consume(1);
      Continue;
    end;
    if FLen < 2 then
      Exit;
    if FBuf[1] <> VentSync2 then
    begin
      Discard;
      Consume(1);
      Continue;
    end;
    if FLen < 3 then
      Exit;
    PayLen := FBuf[2];
    if (PayLen < 7) or (PayLen > VentMaxPayload) then
    begin
      Inc(FStats.FramingErrors);
      Discard;
      Consume(1);
      Continue;
    end;
    FrameLen := 3 + PayLen + 2;
    if FLen < FrameLen then
      Exit;
    Crc := Crc16Ccitt(FBuf[2], PayLen + 1);
    Got := (Word(FBuf[3 + PayLen]) shl 8) or FBuf[4 + PayLen];
    if Crc <> Got then
    begin
      Inc(FStats.ChecksumErrors);
      Discard;
      Consume(1);  // rescan: a real frame may start inside this one
      Continue;
    end;
    HandlePayload(3, PayLen);
    Consume(FrameLen);
  end;
end;

procedure TVentilatorDriver.HandlePayload(Start, Len: Integer);
var
  MsgType: Byte;
  Seq: Word;
  Secs: Cardinal;
  Count, I, Off: Integer;
  Batch: TObservationBatch;
  P: TVentParam;
  Raw: SmallInt;
  Flags: Byte;
  Quality: TQuality;
begin
  MsgType := FBuf[Start];
  Seq := (Word(FBuf[Start + 1]) shl 8) or FBuf[Start + 2];
  Secs := (Cardinal(FBuf[Start + 3]) shl 24) or (Cardinal(FBuf[Start + 4]) shl 16) or
          (Cardinal(FBuf[Start + 5]) shl 8) or FBuf[Start + 6];

  case MsgType of
    VentMsgHeartbeat:
      begin
        Inc(FStats.ControlFrames);
        TrackSequence(Seq);
        Exit;
      end;
    VentMsgMeasurement: ;
  else
    Inc(FStats.ContentErrors);
    Exit;
  end;

  if Len < 8 then
  begin
    Inc(FStats.ContentErrors);
    Exit;
  end;
  Count := FBuf[Start + 7];
  if Len <> 8 + 4 * Count then
  begin
    Inc(FStats.ContentErrors);
    Exit;
  end;

  Batch.Sequence := Seq;
  Batch.Timestamp := IncSecond(VentEpoch, Secs);
  Batch.Observations := nil;
  for I := 0 to Count - 1 do
  begin
    Off := Start + 8 + 4 * I;
    Raw := SmallInt((Word(FBuf[Off + 1]) shl 8) or FBuf[Off + 2]);
    Flags := FBuf[Off + 3];
    if not FindVentParam(FBuf[Off], P) then
    begin
      Inc(FStats.UnknownParams);
      Continue;
    end;
    if (Flags and VentFlagInvalid) <> 0 then
      Quality := qInvalid
    else if (Flags and VentFlagQuestionable) <> 0 then
      Quality := qQuestionable
    else
      Quality := qValid;
    AddObservation(Batch, NumericObs(P.Code, Raw / P.Scale, Quality));
  end;
  Emit(Batch);
end;

initialization
  RegisterDriver(TVentilatorDriver);
end.
