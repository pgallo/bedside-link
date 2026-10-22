unit TestHL7;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ObsModel, HL7Encoder, TestHelpers;

type
  THL7Tests = class(TTestCase)
  private
    FEnc: THL7Encoder;
    function Field(const Segment: string; Index: Integer): string;
    function SampleBatch: TObservationBatch;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EscapesAllDelimiters;
    procedure EscapeOrderDoesNotDoubleEscape;
    procedure UnescapeRoundTrip;
    procedure UnescapeHexAndUnknownSequences;
    procedure MessageHasExpectedSegments;
    procedure MshFields;
    procedure ControlIdIncrements;
    procedure ObxValueTypesUnitsAndStatus;
    procedure InvalidObservationHasEmptyValue;
    procedure TextValueIsEscapedAndFieldCountStable;
    procedure AbnormalFlagsInObx8;
    procedure VisitIdIsStablePerBed;
    procedure MllpFraming;
    procedure DecimalSeparatorIsLocaleIndependent;
  end;

implementation

procedure THL7Tests.SetUp;
begin
  FEnc := THL7Encoder.Create(DefaultHL7Options, 41);
end;

procedure THL7Tests.TearDown;
begin
  FEnc.Free;
end;

function THL7Tests.Field(const Segment: string; Index: Integer): string;
var
  F: TStringArray;
begin
  F := SplitStr(Segment, '|');
  if Index <= High(F) then
    Result := F[Index]
  else
    Result := '';
end;

function THL7Tests.SampleBatch: TObservationBatch;
begin
  Result := MakeBatch('BED03', 30, [NumericObs('HR', 131), NumericObs('TEMP', 37.25),
    TextObs('INF_DRUG', 'Drug A|B^C&D~E\F')]);
  Result.DeviceId := 'MON-9';
  Result.DeviceKind := 'monitor';
  Result.Sequence := 17;
end;

procedure THL7Tests.EscapesAllDelimiters;
begin
  AssertEquals('a\F\b\S\c\T\d\R\e\E\f', HL7Escape('a|b^c&d~e\f'));
  AssertEquals('line1\X0D\\X0A\line2', HL7Escape('line1'#13#10'line2'));
  AssertEquals('plain text 12.5', HL7Escape('plain text 12.5'));
end;

procedure THL7Tests.EscapeOrderDoesNotDoubleEscape;
begin
  // A naive chain of string replacements that handles '\' after '|' would
  // turn '|' into '\E\F\E\'. One pass per character avoids that.
  AssertEquals('\F\', HL7Escape('|'));
  AssertEquals('\E\F\E\', HL7Escape('\F\'));
end;

procedure THL7Tests.UnescapeRoundTrip;
const
  Samples: array[0..4] of string = ('', 'a|b^c&d~e\f', '\\\\', 'x'#13'y', 'Heparin & NaCl 0.9%^50');
var
  S: string;
begin
  for S in Samples do
    AssertEquals(S, HL7Unescape(HL7Escape(S)));
end;

procedure THL7Tests.UnescapeHexAndUnknownSequences;
begin
  AssertEquals('A'#13'B', HL7Unescape('A\X0D\B'));
  AssertEquals('\H\bold\N\', HL7Unescape('\H\bold\N\'));
  AssertEquals('tail\', HL7Unescape('tail\'));
end;

procedure THL7Tests.MessageHasExpectedSegments;
var
  Segs: TStringArray;
  Msg: string;
begin
  Msg := FEnc.Encode(SampleBatch, T0);
  AssertEquals(#13, Msg[Length(Msg)]);
  AssertEquals(0, Pos(#10, Msg));
  Segs := HL7Segments(Msg);
  AssertEquals(7, Length(Segs));
  AssertEquals('MSH', Copy(Segs[0], 1, 3));
  AssertEquals('PID', Copy(Segs[1], 1, 3));
  AssertEquals('PV1', Copy(Segs[2], 1, 3));
  AssertEquals('OBR', Copy(Segs[3], 1, 3));
  AssertEquals('OBX|1|', Copy(Segs[4], 1, 6));
  AssertEquals('OBX|3|', Copy(Segs[6], 1, 6));
end;

procedure THL7Tests.MshFields;
var
  Msh: string;
begin
  Msh := HL7Segments(FEnc.Encode(SampleBatch, T0))[0];
  // MSH-1 is the field separator itself, so split index n is MSH-(n+1).
  AssertEquals('^~\&', Field(Msh, 1));
  AssertEquals('BEDSIDELINK', Field(Msh, 2));
  AssertEquals('20261020080000', Field(Msh, 6));
  AssertEquals('ORU^R01^ORU_R01', Field(Msh, 8));
  AssertEquals('BED00000041', Field(Msh, 9));
  AssertEquals('T', Field(Msh, 10));
  AssertEquals('2.5', Field(Msh, 11));
end;

procedure THL7Tests.ControlIdIncrements;
begin
  FEnc.Encode(SampleBatch, T0);
  AssertEquals('BED00000042', Field(HL7Segments(FEnc.Encode(SampleBatch, T0))[0], 9));
  AssertEquals(43, FEnc.NextControlId);
end;

procedure THL7Tests.ObxValueTypesUnitsAndStatus;
var
  Segs: TStringArray;
  B: TObservationBatch;
begin
  B := SampleBatch;
  B.Observations[1].Quality := qQuestionable;
  Segs := HL7Segments(FEnc.Encode(B, T0));
  AssertEquals('NM', Field(Segs[4], 2));
  AssertEquals('HR^Heart rate^L', Field(Segs[4], 3));
  AssertEquals('131', Field(Segs[4], 5));
  AssertEquals('/min^/min^UCUM', Field(Segs[4], 6));
  AssertEquals('F', Field(Segs[4], 11));
  AssertEquals('20261020080030', Field(Segs[4], 14));
  AssertEquals('37.3', Field(Segs[5], 5));  // 1 decimal for TEMP
  AssertEquals('R', Field(Segs[5], 11));
  AssertEquals('ST', Field(Segs[6], 2));
end;

procedure THL7Tests.InvalidObservationHasEmptyValue;
var
  Obx: string;
begin
  Obx := HL7Segments(FEnc.Encode(MakeBatch('BED01', 0, [NumericObs('SPO2', 0, qInvalid)]), T0))[4];
  AssertEquals('', Field(Obx, 5));
  AssertEquals('X', Field(Obx, 11));
end;

procedure THL7Tests.TextValueIsEscapedAndFieldCountStable;
var
  Obx: string;
  Plain: TStringArray;
begin
  Obx := HL7Segments(FEnc.Encode(SampleBatch, T0))[6];
  AssertEquals('Drug A\F\B\S\C\T\D\R\E\E\F', Field(Obx, 5));
  AssertEquals('Drug A|B^C&D~E\F', HL7Unescape(Field(Obx, 5)));
  Plain := SplitStr(HL7Segments(FEnc.Encode(SampleBatch, T0))[4], '|');
  AssertEquals(Length(Plain), Length(SplitStr(Obx, '|')));
end;

procedure THL7Tests.AbnormalFlagsInObx8;
var
  Flags: TAbnormalFlags;
  Segs: TStringArray;
begin
  Flags := nil;
  SetLength(Flags, 1);
  Flags[0].Code := 'HR';
  Flags[0].Flag := 'H';
  Segs := HL7Segments(FEnc.Encode(SampleBatch, T0, Flags));
  AssertEquals('H', Field(Segs[4], 8));
  AssertEquals('', Field(Segs[5], 8));
end;

procedure THL7Tests.VisitIdIsStablePerBed;
begin
  AssertEquals(SyntheticVisitId('BED01'), SyntheticVisitId('BED01'));
  AssertFalse(SyntheticVisitId('BED01') = SyntheticVisitId('BED02'));
  AssertEquals(7, Length(SyntheticVisitId('BED01')));
end;

procedure THL7Tests.MllpFraming;
var
  W: string;
begin
  W := MllpWrap('MSH|x'#13);
  AssertEquals(#$0B, W[1]);
  AssertEquals(#$1C#$0D, Copy(W, Length(W) - 1, 2));
end;

procedure THL7Tests.DecimalSeparatorIsLocaleIndependent;
var
  Saved: Char;
  Obx: string;
begin
  Saved := DefaultFormatSettings.DecimalSeparator;
  DefaultFormatSettings.DecimalSeparator := ',';
  try
    Obx := HL7Segments(FEnc.Encode(MakeBatch('BED01', 0, [NumericObs('MV', 7.5)]), T0))[4];
    AssertEquals('7.50', Field(Obx, 5));
  finally
    DefaultFormatSettings.DecimalSeparator := Saved;
  end;
end;

initialization
  RegisterTest(THL7Tests);
end.
