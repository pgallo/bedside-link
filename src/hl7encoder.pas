{ HL7 v2.5 ORU^R01 encoder for normalised observation batches.

  One batch becomes one message:
    MSH  header, control id, version 2.5
    PID  synthetic visit-scoped identifier (no demographics; the gateway knows
         beds, not people, and patient matching belongs downstream)
    PV1  assigned location: point of care / room / bed
    OBR  one order per device frame, placer id = device id + sequence
    OBX  one per observation, NM for numbers and ST for text

  Observation quality maps to OBX-11 result status: valid -> F (final),
  questionable -> R (not verified), invalid -> X (could not be obtained, value
  left empty). Abnormal flags (OBX-8) come from the alarm engine when the
  caller passes them in. }
unit HL7Encoder;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ObsModel;

const
  HL7SegmentTerminator = #13;
  MllpStart = #$0B;
  MllpEnd = #$1C#$0D;

type
  { Optional per-parameter abnormal flag, e.g. ('HR', 'H'). }
  TAbnormalFlag = record
    Code: string;
    Flag: string;
  end;
  TAbnormalFlags = array of TAbnormalFlag;

  THL7Options = record
    SendingApp: string;
    SendingFacility: string;
    ReceivingApp: string;
    ReceivingFacility: string;
    PointOfCare: string;
    ProcessingId: string;  // P production, T training, D debugging
  end;

  THL7Encoder = class
  private
    FOptions: THL7Options;
    FNextControlId: Int64;
    function AbnormalFor(const Flags: TAbnormalFlags; const Code: string): string;
  public
    constructor Create(const AOptions: THL7Options; AFirstControlId: Int64 = 1);
    { MessageTime is the gateway clock used in MSH-7; observation times come
      from the device frame. }
    function Encode(const Batch: TObservationBatch; MessageTime: TDateTime;
      const Flags: TAbnormalFlags = nil): string;
    property NextControlId: Int64 read FNextControlId;
  end;

function DefaultHL7Options: THL7Options;
{ Escapes field separator, component, repetition, escape and subcomponent
  characters plus CR/LF, using the default MSH-1/MSH-2 delimiters |^~\&. }
function HL7Escape(const S: string): string;
function HL7Unescape(const S: string): string;
function HL7Timestamp(T: TDateTime): string;
{ Deterministic visit id derived from the bed, so that every message for the
  same bed carries the same synthetic identifier within a run. }
function SyntheticVisitId(const BedId: string): string;
function MllpWrap(const Msg: string): string;
function HL7Segments(const Msg: string): TStringArray;

implementation

uses
  Checksums;

function DefaultHL7Options: THL7Options;
begin
  Result.SendingApp := 'BEDSIDELINK';
  Result.SendingFacility := 'ICU-LAB';
  Result.ReceivingApp := 'OBS-SINK';
  Result.ReceivingFacility := 'LAB';
  Result.PointOfCare := 'ICU1';
  Result.ProcessingId := 'T';
end;

function HL7Escape(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
    case C of
      '\': Result := Result + '\E\';
      '|': Result := Result + '\F\';
      '^': Result := Result + '\S\';
      '&': Result := Result + '\T\';
      '~': Result := Result + '\R\';
      #13: Result := Result + '\X0D\';
      #10: Result := Result + '\X0A\';
    else
      Result := Result + C;
    end;
end;

function HL7Unescape(const S: string): string;
var
  I, J, K: Integer;
  Seq: string;
  B: Byte;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] <> '\' then
    begin
      Result := Result + S[I];
      Inc(I);
      Continue;
    end;
    J := I + 1;
    while (J <= Length(S)) and (S[J] <> '\') do
      Inc(J);
    if J > Length(S) then
    begin
      // unterminated escape: keep the text literally
      Result := Result + Copy(S, I, MaxInt);
      Break;
    end;
    Seq := Copy(S, I + 1, J - I - 1);
    if Seq = 'E' then Result := Result + '\'
    else if Seq = 'F' then Result := Result + '|'
    else if Seq = 'S' then Result := Result + '^'
    else if Seq = 'T' then Result := Result + '&'
    else if Seq = 'R' then Result := Result + '~'
    else if (Length(Seq) >= 3) and (Seq[1] = 'X') and Odd(Length(Seq)) then
    begin
      K := 2;
      while K < Length(Seq) do
      begin
        if ParseHexByte(Copy(Seq, K, 2), B) then
          Result := Result + Chr(B);
        Inc(K, 2);
      end;
    end
    else
      Result := Result + '\' + Seq + '\';
    I := J + 1;
  end;
end;

function HL7Timestamp(T: TDateTime): string;
begin
  Result := FormatCompactTimestamp(T);
end;

function SyntheticVisitId(const BedId: string): string;
var
  H: Cardinal;
  C: Char;
begin
  // FNV-1a, truncated; stable across runs and platforms.
  H := 2166136261;
  for C in BedId do
  begin
    H := H xor Ord(C);
    {$Q-}{$R-}
    H := H * 16777619;
    {$Q+}{$R+}
  end;
  Result := 'V' + IntToHex(H and $FFFFFF, 6);
end;

function MllpWrap(const Msg: string): string;
begin
  Result := MllpStart + Msg + MllpEnd;
end;

function HL7Segments(const Msg: string): TStringArray;
var
  Parts: TStringArray;
  I, N: Integer;
begin
  Parts := SplitStr(Msg, HL7SegmentTerminator);
  Result := nil;
  N := 0;
  for I := 0 to High(Parts) do
    if Parts[I] <> '' then
    begin
      SetLength(Result, N + 1);
      Result[N] := Parts[I];
      Inc(N);
    end;
end;

{ THL7Encoder }

constructor THL7Encoder.Create(const AOptions: THL7Options; AFirstControlId: Int64);
begin
  inherited Create;
  FOptions := AOptions;
  FNextControlId := AFirstControlId;
end;

function THL7Encoder.AbnormalFor(const Flags: TAbnormalFlags; const Code: string): string;
var
  F: TAbnormalFlag;
begin
  for F in Flags do
    if F.Code = Code then
      Exit(F.Flag);
  Result := '';
end;

function THL7Encoder.Encode(const Batch: TObservationBatch; MessageTime: TDateTime;
  const Flags: TAbnormalFlags): string;
const
  StatusFor: array[TQuality] of string = ('F', 'R', 'X');
var
  ObsTime, ControlId, VisitId, Placer, ValueType, Value, UnitField: string;
  Obs: TObservation;
  Info: TParamInfo;
  SetId: Integer;

  procedure Seg(const S: string);
  begin
    Result := Result + S + HL7SegmentTerminator;
  end;

begin
  Result := '';
  ObsTime := HL7Timestamp(Batch.Timestamp);
  ControlId := Format('%s%.8d', [Copy(FOptions.SendingApp, 1, 3), FNextControlId]);
  Inc(FNextControlId);
  VisitId := SyntheticVisitId(Batch.BedId);
  Placer := HL7Escape(Batch.DeviceId) + '-' + IntToStr(Batch.Sequence);

  Seg('MSH|^~\&|' + HL7Escape(FOptions.SendingApp) + '|' + HL7Escape(FOptions.SendingFacility) +
      '|' + HL7Escape(FOptions.ReceivingApp) + '|' + HL7Escape(FOptions.ReceivingFacility) +
      '|' + HL7Timestamp(MessageTime) + '||ORU^R01^ORU_R01|' + ControlId + '|' +
      FOptions.ProcessingId + '|2.5|||NE|NE');
  Seg('PID|1||' + VisitId + '^^^' + HL7Escape(FOptions.SendingApp) + '^VN||' +
      'UNIDENTIFIED^' + HL7Escape(Batch.BedId));
  Seg('PV1|1|I|' + HL7Escape(FOptions.PointOfCare) + '^^' + HL7Escape(Batch.BedId));
  Seg('OBR|1|' + Placer + '||DEVOBS^Device observations^L|||' + ObsTime +
      '|||||||||||||||' + ObsTime + '||' + HL7Escape(UpperCase(Batch.DeviceKind)) + '|F');

  SetId := 0;
  for Obs in Batch.Observations do
  begin
    Inc(SetId);
    FindParam(Obs.Code, Info);
    if Obs.Kind = vkNumeric then
      ValueType := 'NM'
    else
      ValueType := 'ST';
    if Obs.Quality = qInvalid then
      Value := ''
    else
      Value := HL7Escape(FormatObsValue(Obs));
    if Obs.Units <> '' then
      UnitField := HL7Escape(Obs.Units) + '^' + HL7Escape(Obs.Units) + '^UCUM'
    else
      UnitField := '';
    Seg('OBX|' + IntToStr(SetId) + '|' + ValueType + '|' + HL7Escape(Obs.Code) + '^' +
        HL7Escape(Info.Description) + '^L||' + Value + '|' + UnitField + '||' +
        HL7Escape(AbnormalFor(Flags, Obs.Code)) + '|||' + StatusFor[Obs.Quality] +
        '|||' + ObsTime + '||||' + HL7Escape(Batch.DeviceId));
  end;
end;

end.
