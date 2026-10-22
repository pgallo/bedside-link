{ Normalised observation model shared by every driver, the alarm engine and
  the HL7 encoder. Drivers translate device-specific frames into these
  records; nothing downstream knows which wire protocol produced them. }
unit ObsModel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TQuality = (qValid, qQuestionable, qInvalid);
  TValueKind = (vkNumeric, vkText);

  TObservation = record
    Code: string;       // local parameter code, e.g. HR, SPO2, PIP
    Kind: TValueKind;
    Value: Double;      // meaningful when Kind = vkNumeric
    Text: string;       // meaningful when Kind = vkText
    Units: string;      // UCUM unit string
    Quality: TQuality;
  end;
  TObservationArray = array of TObservation;

  { One decoded device frame: all values share bed, device and timestamp. }
  TObservationBatch = record
    BedId: string;
    DeviceId: string;
    DeviceKind: string;
    Sequence: Cardinal;
    Timestamp: TDateTime;
    Observations: TObservationArray;
  end;

  TParamInfo = record
    Code: string;
    Description: string;
    Units: string;
    Decimals: Integer;
  end;

const
  QualityNames: array[TQuality] of string = ('valid', 'questionable', 'invalid');

var
  { Wire formats and HL7 always use '.' as decimal separator, whatever the
    locale of the host running the gateway. }
  InvariantFS: TFormatSettings;

function FindParam(const Code: string; out Info: TParamInfo): Boolean;
function NumericObs(const Code: string; Value: Double;
  Quality: TQuality = qValid): TObservation;
function TextObs(const Code, Text: string; Quality: TQuality = qValid): TObservation;
procedure AddObservation(var Batch: TObservationBatch; const Obs: TObservation);
function FindObservation(const Batch: TObservationBatch; const Code: string;
  out Obs: TObservation): Boolean;
function FormatObsValue(const Obs: TObservation): string;
function ParseFloatInv(const S: string; out Value: Double): Boolean;
function SplitStr(const S: string; Sep: Char): TStringArray;
function BedIdFromNumber(N: Integer): string;
{ 'yyyymmddhhnnss' <-> TDateTime. Both device protocols and HL7 DTM use it. }
function ParseCompactTimestamp(const S: string; out T: TDateTime): Boolean;
function FormatCompactTimestamp(T: TDateTime): string;

implementation

uses
  DateUtils;

const
  ParamCatalog: array[0..17] of TParamInfo = (
    (Code: 'HR';        Description: 'Heart rate';                 Units: '/min';     Decimals: 0),
    (Code: 'SPO2';      Description: 'Oxygen saturation (SpO2)';   Units: '%';        Decimals: 0),
    (Code: 'RR';        Description: 'Respiratory rate';           Units: '/min';     Decimals: 0),
    (Code: 'TEMP';      Description: 'Body temperature';           Units: 'Cel';      Decimals: 1),
    (Code: 'NIBPS';     Description: 'Non-invasive BP systolic';   Units: 'mm[Hg]';   Decimals: 0),
    (Code: 'NIBPD';     Description: 'Non-invasive BP diastolic';  Units: 'mm[Hg]';   Decimals: 0),
    (Code: 'PIP';       Description: 'Peak inspiratory pressure';  Units: 'cm[H2O]';  Decimals: 1),
    (Code: 'PEEP';      Description: 'PEEP';                       Units: 'cm[H2O]';  Decimals: 1),
    (Code: 'VRR';       Description: 'Ventilator respiratory rate';Units: '/min';     Decimals: 0),
    (Code: 'VT';        Description: 'Tidal volume';               Units: 'mL';       Decimals: 0),
    (Code: 'FIO2';      Description: 'Inspired O2 fraction';       Units: '%';        Decimals: 0),
    (Code: 'MV';        Description: 'Minute volume';              Units: 'L/min';    Decimals: 2),
    (Code: 'INF_RATE';  Description: 'Infusion rate';              Units: 'mL/h';     Decimals: 1),
    (Code: 'INF_VI';    Description: 'Volume infused';             Units: 'mL';       Decimals: 2),
    (Code: 'INF_VTBI';  Description: 'Volume to be infused';       Units: 'mL';       Decimals: 1),
    (Code: 'INF_OCCL';  Description: 'Occlusion detected';         Units: '';         Decimals: 0),
    (Code: 'INF_STATE'; Description: 'Pump state';                 Units: '';         Decimals: 0),
    (Code: 'INF_DRUG';  Description: 'Infusion label';             Units: '';         Decimals: 0)
  );

function FindParam(const Code: string; out Info: TParamInfo): Boolean;
var
  I: Integer;
begin
  for I := Low(ParamCatalog) to High(ParamCatalog) do
    if ParamCatalog[I].Code = Code then
    begin
      Info := ParamCatalog[I];
      Exit(True);
    end;
  Info.Code := Code;
  Info.Description := Code;
  Info.Units := '';
  Info.Decimals := 2;
  Result := False;
end;

function NumericObs(const Code: string; Value: Double; Quality: TQuality): TObservation;
var
  Info: TParamInfo;
begin
  FindParam(Code, Info);
  Result.Code := Code;
  Result.Kind := vkNumeric;
  Result.Value := Value;
  Result.Text := '';
  Result.Units := Info.Units;
  Result.Quality := Quality;
end;

function TextObs(const Code, Text: string; Quality: TQuality): TObservation;
begin
  Result.Code := Code;
  Result.Kind := vkText;
  Result.Value := 0;
  Result.Text := Text;
  Result.Units := '';
  Result.Quality := Quality;
end;

procedure AddObservation(var Batch: TObservationBatch; const Obs: TObservation);
var
  N: Integer;
begin
  N := Length(Batch.Observations);
  SetLength(Batch.Observations, N + 1);
  Batch.Observations[N] := Obs;
end;

function FindObservation(const Batch: TObservationBatch; const Code: string;
  out Obs: TObservation): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Batch.Observations) do
    if Batch.Observations[I].Code = Code then
    begin
      Obs := Batch.Observations[I];
      Exit(True);
    end;
  Result := False;
end;

function FormatObsValue(const Obs: TObservation): string;
var
  Info: TParamInfo;
begin
  if Obs.Kind = vkText then
    Exit(Obs.Text);
  FindParam(Obs.Code, Info);
  Result := FloatToStrF(Obs.Value, ffFixed, 15, Info.Decimals, InvariantFS);
end;

function ParseFloatInv(const S: string; out Value: Double): Boolean;
begin
  Result := (S <> '') and TryStrToFloat(S, Value, InvariantFS);
end;

function SplitStr(const S: string; Sep: Char): TStringArray;
var
  I, Start, N: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = Sep) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

function BedIdFromNumber(N: Integer): string;
begin
  Result := Format('BED%.2d', [N]);
end;

function ParseCompactTimestamp(const S: string; out T: TDateTime): Boolean;
var
  Y, Mo, D, H, Mi, Se, I: Integer;
begin
  T := 0;
  if Length(S) <> 14 then
    Exit(False);
  for I := 1 to 14 do
    if not (S[I] in ['0'..'9']) then
      Exit(False);
  Y := StrToInt(Copy(S, 1, 4));
  Mo := StrToInt(Copy(S, 5, 2));
  D := StrToInt(Copy(S, 7, 2));
  H := StrToInt(Copy(S, 9, 2));
  Mi := StrToInt(Copy(S, 11, 2));
  Se := StrToInt(Copy(S, 13, 2));
  Result := TryEncodeDateTime(Y, Mo, D, H, Mi, Se, 0, T);
end;

function FormatCompactTimestamp(T: TDateTime): string;
begin
  Result := FormatDateTime('yyyymmddhhnnss', T);
end;

initialization
  InvariantFS := DefaultFormatSettings;
  InvariantFS.DecimalSeparator := '.';
  InvariantFS.ThousandSeparator := #0;
end.
