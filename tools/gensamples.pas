{ Generates the recorded byte streams in data/. Output is deterministic, so
  the files in the repository can be regenerated and diffed. Each stream
  carries a short synthetic clinical episode plus deliberate line faults:
  idle fill, noise bursts, checksum errors, truncated frames, corrupted length
  bytes and oversize lines. }
program GenSamples;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, ObsModel, Checksums, DrvMonitor, DrvVentilator,
  DrvInfusion;

const
  Samples = 36;
  HR: array[0..Samples - 1] of Integer = (
    78, 80, 82, 85, 90, 98, 108, 116, 121, 124, 119, 117, 122, 125, 128, 126, 119, 116,
    118, 121, 117, 112, 108, 104, 100, 96, 92, 90, 88, 86, 85, 84, 83, 82, 82, 81);
  SPO2: array[0..Samples - 1] of Integer = (
    97, 97, 96, 97, 96, 95, 94, 93, 91, 89, 87, 86, 85, 86, 88, 90, 91, 92,
    93, 94, 95, 96, 96, 97, 97, 97, 97, 97, 98, 97, 97, 98, 97, 97, 98, 97);
  PIP: array[0..Samples - 1] of Double = (
    22, 22, 23, 22, 23, 24, 23, 24, 26, 30, 34, 37, 38, 38, 37, 36, 33, 31,
    29, 27, 26, 25, 25, 24, 24, 23, 23, 23, 22, 23, 22, 22, 23, 22, 22, 22);

var
  Start: TDateTime;
  OutDir: string;

procedure SaveBytes(const Name: string; const Data: AnsiString);
var
  F: TFileStream;
begin
  F := TFileStream.Create(ConcatPaths([OutDir, Name]), fmCreate);
  try
    if Data <> '' then
      F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
  WriteLn(Format('wrote %-24s %6d bytes', [Name, Length(Data)]));
end;

function F1(V: Double): string;
begin
  Result := FloatToStrF(V, ffFixed, 15, 1, InvariantFS);
end;

function F2(V: Double): string;
begin
  Result := FloatToStrF(V, ffFixed, 15, 2, InvariantFS);
end;

procedure GenMonitor;
var
  S, Payload, Frame, Items, SpO2Text: AnsiString;
  I: Integer;
  T: TDateTime;
begin
  S := #13#10#13#10;  // idle fill before the first frame
  for I := 0 to Samples - 1 do
  begin
    T := IncSecond(Start, 10 * I);
    SpO2Text := IntToStr(SPO2[I]);
    if I = 18 then SpO2Text := SpO2Text + '?';  // motion artefact
    if I = 25 then SpO2Text := '---';           // probe off
    Items := Format('HR=%d;SPO2=%s;RR=%d;TEMP=%s',
      [HR[I], SpO2Text, 16 + (I mod 5), F1(37.2 + I * 0.012)]);
    if I mod 6 = 0 then
      Items := Items + Format(';NIBPS=%d;NIBPD=%d', [118 + I div 3, 74 + I div 6]);
    if I = 7 then
      Items := Items + ';ST1=0.1';  // parameter the gateway does not know
    Payload := Format('MON|%d|%s|%s', [I, FormatCompactTimestamp(T), Items]);
    Frame := TMonitorDriver.EncodeFrame(Payload);
    case I of
      12: Frame[Length(Frame)] := Chr(Ord(Frame[Length(Frame)]) xor 1);  // bad checksum
      20: SetLength(Frame, Length(Frame) - 3);                            // lost ETX + CK
      27: begin Frame[Length(Frame) - 1] := 'Z'; Frame[Length(Frame)] := 'Z'; end;
    end;
    S := S + Frame + #13#10;
    if I = 4 then
      S := S + #$FF#$00'noise'#$7F#$03'41';  // burst, including a stray ETX
  end;
  SaveBytes('monitor_bed01.bin', S);
end;

procedure GenVentilator;
var
  S, Frame: AnsiString;
  I, Seq: Integer;
  T: TDateTime;
  Items: TVentItemArray;

  procedure Item(Id: Byte; Value: Double; Flags: Byte = 0);
  var
    N: Integer;
  begin
    N := Length(Items);
    SetLength(Items, N + 1);
    Items[N].Id := Id;
    Items[N].Value := Value;
    Items[N].Flags := Flags;
  end;

var
  Vt, Rr, FiO2: Double;
begin
  S := #$00#$00#$A5#$13;  // line noise with a false SYNC1
  Seq := 0;
  for I := 0 to Samples - 1 do
  begin
    T := IncSecond(Start, 10 * I + 3);
    Items := nil;
    Vt := 450 + 10 * ((I * 7) mod 5) - 20;
    Rr := 16 + (I div 9);
    if I < 12 then FiO2 := 40 else FiO2 := 60;
    Item(1, PIP[I]);
    Item(2, 5.0);
    Item(3, Rr);
    if I = 15 then
      Item(4, Vt, VentFlagQuestionable)  // leak suspected
    else
      Item(4, Vt);
    Item(5, FiO2);
    Item(6, Vt * Rr / 1000);
    if I = 3 then
      Item(9, 1);  // parameter id unknown to this driver version
    Frame := TVentilatorDriver.EncodeMeasurement(Seq, T, Items);
    Inc(Seq);
    case I of
      6:  Frame[10] := Chr(Ord(Frame[10]) xor $10);  // bit flip in payload
      14: Frame[3] := Chr(250);                       // LEN beyond protocol maximum
      22: Frame[3] := Chr(Ord(Frame[3]) + 20);        // plausible but wrong LEN
    end;
    S := S + Frame;
    if I mod 5 = 4 then
    begin
      S := S + TVentilatorDriver.EncodeHeartbeat(Seq, T);
      Inc(Seq);
    end;
    if I = 9 then
      S := S + #$A5#$A5#$5A#$03;  // sync pattern followed by an impossible LEN
  end;
  SaveBytes('ventilator_bed01.bin', S);
end;

procedure GenPump;
const
  Drug = 'Heparin 25000 U & NaCl 0.9%^50 mL';
var
  S, Body, State: AnsiString;
  I: Integer;
  T: TDateTime;
  Vi, Rate: Double;
  Occl: Integer;
begin
  S := 'PUMP SIM boot' + #13#10 + 'self test OK' + #13#10;
  Vi := 0;
  for I := 0 to 11 do
  begin
    T := IncSecond(Start, 30 * I + 7);
    if (I >= 6) and (I <= 8) then
    begin
      State := 'OCCLUDED';
      Rate := 0;
      Occl := 1;
    end
    else
    begin
      State := 'RUNNING';
      Rate := 12.5;
      Occl := 0;
    end;
    Body := Format('PUMP,seq=%d,ts=%s,state=%s,rate=%s,vi=%s,vtbi=%s,occl=%d,bat=%d,drug=%s',
      [I, FormatCompactTimestamp(T), State, F1(Rate), F2(Vi), F1(50.0 - Vi), Occl,
       90 - I, Drug]);
    Vi := Vi + Rate * 30 / 3600;
    case I of
      4: S := S + '$' + Body + '*' + IntToHex(Xor8(Body) xor $5A, 2) + #13#10;
      10: S := S + '$' + Body + #13#10;  // checksum missing
    else
      S := S + TInfusionDriver.EncodeLine(Body);
    end;
    if I = 2 then
      S := S + '$PUMP,' + StringOfChar('X', 250) + #13#10;  // runaway line
  end;
  SaveBytes('pump_bed02.bin', S);
end;

begin
  if ParamCount > 0 then
    OutDir := ParamStr(1)
  else
    OutDir := 'data';
  ForceDirectories(OutDir);
  Start := EncodeDateTime(2026, 10, 20, 8, 30, 0, 0);
  GenMonitor;
  GenVentilator;
  GenPump;
end.
