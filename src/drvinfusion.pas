{ Simulated infusion pump protocol: one record per line, with a trailing XOR checksum.

    $PUMP,seq=41,ts=20261020083015,state=RUNNING,rate=12.5,vi=3.20,vtbi=50.0,occl=0,drug=Heparin 25000 U & NaCl*5B<CR><LF>

  The two hex digits after the LAST '*' are the XOR of every byte between '$'
  and that '*'. Keys may appear in any order and unknown keys are ignored, so
  newer pump firmware can add fields without breaking the gateway. Lines that
  do not start with '$' (boot banners, service menus) are discarded. The drug
  label is free text and may contain HL7 delimiters; escaping happens in the
  encoder, not here. }
unit DrvInfusion;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ObsModel, DeviceDriver;

const
  PumpMaxLine = 200;

type
  TInfusionDriver = class(TDeviceDriver)
  private
    FLine: AnsiString;
    FOverflow: Boolean;
    procedure HandleLine(const Line: AnsiString);
    procedure HandleRecord(const Body: AnsiString);
  protected
    procedure ProcessByte(B: Byte); override;
  public
    class function Kind: string; override;
    class function Description: string; override;
    procedure Reset; override;
    class function EncodeLine(const Body: AnsiString): AnsiString;
  end;

implementation

uses
  Checksums;

class function TInfusionDriver.Kind: string;
begin
  Result := 'infusion';
end;

class function TInfusionDriver.Description: string;
begin
  Result := 'Infusion pump, line-oriented key=value records with XOR checksum';
end;

class function TInfusionDriver.EncodeLine(const Body: AnsiString): AnsiString;
begin
  Result := '$' + Body + '*' + IntToHex(Xor8(Body), 2) + #13#10;
end;

procedure TInfusionDriver.Reset;
begin
  Discard(Length(FLine));
  FLine := '';
  FOverflow := False;
end;

procedure TInfusionDriver.ProcessByte(B: Byte);
begin
  if B = 10 then
  begin
    if FOverflow then
      FOverflow := False  // overflowing line already counted and discarded
    else
      HandleLine(FLine);
    Discard;  // the LF itself
    FLine := '';
  end
  else if FOverflow then
    Discard
  else if Length(FLine) >= PumpMaxLine then
  begin
    Inc(FStats.FramingErrors);
    Discard(Length(FLine) + 1);
    FLine := '';
    FOverflow := True;
  end
  else
    FLine := FLine + AnsiChar(B);
end;

procedure TInfusionDriver.HandleLine(const Line: AnsiString);
var
  L, Body: AnsiString;
  Star: Integer;
  Got: Byte;
begin
  L := Line;
  if (L <> '') and (L[Length(L)] = #13) then
  begin
    SetLength(L, Length(L) - 1);
    Discard;
  end;
  if L = '' then
    Exit;
  if L[1] <> '$' then
  begin
    Discard(Length(L));  // banner or noise, not a framing error
    Exit;
  end;
  Star := LastDelimiter('*', L);
  if (Star = 0) or (Length(L) - Star <> 2) or not ParseHexByte(Copy(L, Star + 1, 2), Got) then
  begin
    Inc(FStats.FramingErrors);
    Discard(Length(L));
    Exit;
  end;
  Body := Copy(L, 2, Star - 2);
  if Xor8(Body) <> Got then
  begin
    Inc(FStats.ChecksumErrors);
    Discard(Length(L));
    Exit;
  end;
  HandleRecord(Body);
end;

procedure TInfusionDriver.HandleRecord(const Body: AnsiString);
var
  Fields: TStringArray;
  Batch: TObservationBatch;
  I, Eq, Seq: Integer;
  Key, Val: string;
  V: Double;
  HaveSeq, HaveTs: Boolean;

  procedure AddNum(const Code, S: string);
  begin
    if ParseFloatInv(S, V) then
      AddObservation(Batch, NumericObs(Code, V))
    else
      AddObservation(Batch, NumericObs(Code, 0, qInvalid));
  end;

begin
  Fields := SplitStr(Body, ',');
  if (Length(Fields) < 3) or (Fields[0] <> 'PUMP') then
  begin
    Inc(FStats.ContentErrors);
    Exit;
  end;
  Batch.Observations := nil;
  HaveSeq := False;
  HaveTs := False;
  for I := 1 to High(Fields) do
  begin
    Eq := Pos('=', Fields[I]);
    if Eq = 0 then
    begin
      Inc(FStats.ContentErrors);
      Continue;
    end;
    Key := LowerCase(Copy(Fields[I], 1, Eq - 1));
    Val := Copy(Fields[I], Eq + 1, MaxInt);
    if Key = 'seq' then
      HaveSeq := TryStrToInt(Val, Seq) and (Seq >= 0)
    else if Key = 'ts' then
      HaveTs := ParseCompactTimestamp(Val, Batch.Timestamp)
    else if Key = 'state' then
      AddObservation(Batch, TextObs('INF_STATE', UpperCase(Val)))
    else if Key = 'rate' then
      AddNum('INF_RATE', Val)
    else if Key = 'vi' then
      AddNum('INF_VI', Val)
    else if Key = 'vtbi' then
      AddNum('INF_VTBI', Val)
    else if Key = 'occl' then
      AddNum('INF_OCCL', Val)
    else if Key = 'drug' then
      AddObservation(Batch, TextObs('INF_DRUG', Val))
    else
      Inc(FStats.UnknownParams);
  end;
  if not (HaveSeq and HaveTs) then
  begin
    Inc(FStats.ContentErrors);
    Exit;
  end;
  Batch.Sequence := Seq;
  Emit(Batch);
end;

initialization
  RegisterDriver(TInfusionDriver);
end.
