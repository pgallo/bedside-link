{ Simulated bedside monitor protocol: ASCII frames delimited by STX/ETX.

    <STX>MON|<seq>|<yyyymmddhhnnss>|HR=72;SPO2=98;TEMP=36.8<ETX><CK>

  <CK> is two uppercase hex digits: the modulo-256 sum of every byte between
  STX and ETX (exclusive). A value of '---' marks an invalid measurement and a
  trailing '?' a questionable one (e.g. motion artefact). Bytes outside frames
  (CR/LF idle fill, line noise) are discarded while hunting for STX. }
unit DrvMonitor;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ObsModel, DeviceDriver;

const
  STX = $02;
  ETX = $03;
  MonitorMaxPayload = 512;

type
  TMonitorState = (msHunt, msPayload, msCk1, msCk2);

  TMonitorDriver = class(TDeviceDriver)
  private
    FState: TMonitorState;
    FPayload: AnsiString;
    FCk1: AnsiChar;
    procedure Restart;
    procedure HandleFrame(const Payload: AnsiString);
  protected
    procedure ProcessByte(B: Byte); override;
  public
    class function Kind: string; override;
    class function Description: string; override;
    procedure Reset; override;
    class function EncodeFrame(const Payload: AnsiString): AnsiString;
  end;

implementation

uses
  Checksums;

class function TMonitorDriver.Kind: string;
begin
  Result := 'monitor';
end;

class function TMonitorDriver.Description: string;
begin
  Result := 'Bedside monitor, STX/ETX ASCII frames with sum-8 checksum';
end;

class function TMonitorDriver.EncodeFrame(const Payload: AnsiString): AnsiString;
begin
  Result := Chr(STX) + Payload + Chr(ETX) + IntToHex(Sum8(Payload), 2);
end;

procedure TMonitorDriver.Reset;
begin
  if FState <> msHunt then
    Discard(Length(FPayload) + 1);
  Restart;
end;

procedure TMonitorDriver.Restart;
begin
  FState := msHunt;
  FPayload := '';
end;

procedure TMonitorDriver.ProcessByte(B: Byte);
var
  Expected, Got: Byte;
  CkText: AnsiString;
begin
  case FState of
    msHunt:
      if B = STX then
      begin
        FPayload := '';
        FState := msPayload;
      end
      else
        Discard;

    msPayload:
      if B = ETX then
        FState := msCk1
      else if B = STX then
      begin
        // A new start inside a frame means the previous frame lost its tail.
        // Abandon it but keep this STX as the start of the next frame.
        Inc(FStats.FramingErrors);
        Discard(Length(FPayload) + 1);
        FPayload := '';
      end
      else if Length(FPayload) >= MonitorMaxPayload then
      begin
        Inc(FStats.FramingErrors);
        Discard(Length(FPayload) + 2);
        Restart;
      end
      else
        FPayload := FPayload + AnsiChar(B);

    msCk1:
      begin
        FCk1 := AnsiChar(B);
        FState := msCk2;
      end;

    msCk2:
      begin
        CkText := FCk1 + AnsiChar(B);
        Expected := Sum8(FPayload);
        if not ParseHexByte(CkText, Got) then
        begin
          Inc(FStats.FramingErrors);
          Discard(Length(FPayload) + 4);
        end
        else if Got <> Expected then
        begin
          Inc(FStats.ChecksumErrors);
          Discard(Length(FPayload) + 4);
        end
        else
          HandleFrame(FPayload);
        Restart;
      end;
  end;
end;

procedure TMonitorDriver.HandleFrame(const Payload: AnsiString);
var
  Fields, Items, KV: TStringArray;
  Batch: TObservationBatch;
  Seq: Integer;
  Item, Code, Raw: string;
  Quality: TQuality;
  V: Double;
  Info: TParamInfo;
begin
  Fields := SplitStr(Payload, '|');
  if (Length(Fields) <> 4) or (Fields[0] <> 'MON') or
     not TryStrToInt(Fields[1], Seq) or (Seq < 0) or
     not ParseCompactTimestamp(Fields[2], Batch.Timestamp) then
  begin
    Inc(FStats.ContentErrors);
    Discard(Length(Payload) + 4);
    Exit;
  end;
  Batch.Sequence := Seq;
  Batch.Observations := nil;

  Items := SplitStr(Fields[3], ';');
  for Item in Items do
  begin
    if Item = '' then
      Continue;
    KV := SplitStr(Item, '=');
    if Length(KV) <> 2 then
    begin
      Inc(FStats.ContentErrors);
      Continue;
    end;
    Code := UpperCase(KV[0]);
    Raw := KV[1];
    if not FindParam(Code, Info) then
    begin
      Inc(FStats.UnknownParams);
      Continue;
    end;
    Quality := qValid;
    if Raw = '---' then
    begin
      AddObservation(Batch, NumericObs(Code, 0, qInvalid));
      Continue;
    end;
    if (Raw <> '') and (Raw[Length(Raw)] = '?') then
    begin
      Quality := qQuestionable;
      SetLength(Raw, Length(Raw) - 1);
    end;
    if ParseFloatInv(Raw, V) then
      AddObservation(Batch, NumericObs(Code, V, Quality))
    else
      Inc(FStats.ContentErrors);
  end;
  Emit(Batch);
end;

initialization
  RegisterDriver(TMonitorDriver);
end.
