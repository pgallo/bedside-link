unit TestAlarms;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ObsModel, AlarmEngine, HL7Encoder, TestHelpers;

type
  TAlarmTests = class(TTestCase)
  private
    FEngine: TAlarmEngine;
    FT: Integer;  // seconds since T0 for the next sample
    function Feed(const Code: string; V: Double; Q: TQuality = qValid;
      StepSeconds: Integer = 10): TAlarmEvents;
    procedure AssertTransition(const Events: TAlarmEvents; T: TAlarmTransition;
      C: TAlarmCondition);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure HighThresholdRaisesOnce;
    procedure HysteresisSuppressesChatter;
    procedure LowThresholdWithHysteresis;
    procedure OnsetSamplesFilterSpikes;
    procedure LatchingHoldsUntilAcknowledged;
    procedure AcknowledgeWhileActiveClearsWithoutLatching;
    procedure LatchedAlarmRetriggersWithoutSecondRaise;
    procedure RateOfChangeWithHysteresis;
    procedure RateIgnoresQuestionableSamples;
    procedure InvalidSamplesDoNotChangeState;
    procedure BedsAreIndependent;
    procedure PrioritiesPerCondition;
    procedure AbnormalFlagsReflectActiveState;
    procedure IniDefaultsAndOverrides;
    procedure IniRejectsBadConfig;
    procedure LoadsShippedConfig;
  end;

implementation

const
  Config =
    '[defaults]'#10'Priority=low'#10'Latching=false'#10 +
    '[HR]'#10'HighLimit=120'#10'LowLimit=45'#10'Hysteresis=5'#10 +
    'RateLimit=30'#10'RateHysteresis=10'#10'HighPriority=medium'#10'LowPriority=high'#10 +
    '[SPO2]'#10'LowLimit=90'#10'Hysteresis=2'#10'Priority=high'#10'Latching=true'#10 +
    '[PIP]'#10'HighLimit=35'#10'Hysteresis=3'#10'OnsetSamples=3'#10;

procedure TAlarmTests.SetUp;
begin
  FEngine := TAlarmEngine.Create;
  FEngine.LoadFromText(Config);
  FT := 0;
end;

procedure TAlarmTests.TearDown;
begin
  FEngine.Free;
end;

function TAlarmTests.Feed(const Code: string; V: Double; Q: TQuality;
  StepSeconds: Integer): TAlarmEvents;
begin
  Inc(FT, StepSeconds);
  Result := FEngine.Process(MakeBatch('BED01', FT, [NumericObs(Code, V, Q)]));
end;

procedure TAlarmTests.AssertTransition(const Events: TAlarmEvents; T: TAlarmTransition;
  C: TAlarmCondition);
begin
  AssertEquals('event count', 1, Length(Events));
  AssertEquals('transition', TransitionNames[T], TransitionNames[Events[0].Transition]);
  AssertEquals('condition', ConditionNames[C], ConditionNames[Events[0].Condition]);
end;

procedure TAlarmTests.HighThresholdRaisesOnce;
begin
  AssertEquals(0, Length(Feed('HR', 110, qValid, 60)));
  AssertTransition(Feed('HR', 125, qValid, 60), atRaised, acHigh);
  AssertEquals(0, Length(Feed('HR', 130, qValid, 60)));
  AssertEquals(1, Length(FEngine.ActiveAlarms));
end;

procedure TAlarmTests.HysteresisSuppressesChatter;
const
  // Oscillates across the 120 limit but never reaches the 115 clear point.
  Series: array[0..7] of Double = (121, 119, 122, 118, 121, 116, 120.5, 117);
var
  V: Double;
  Raised, Cleared: Integer;
  E: TAlarmEvent;
begin
  Raised := 0;
  Cleared := 0;
  for V in Series do
    for E in Feed('HR', V, qValid, 60) do
      case E.Transition of
        atRaised: Inc(Raised);
        atCleared: Inc(Cleared);
      end;
  AssertEquals('raised', 1, Raised);
  AssertEquals('cleared', 0, Cleared);
  AssertEquals(0, Length(Feed('HR', 115.5, qValid, 60)));
  AssertTransition(Feed('HR', 115, qValid, 60), atCleared, acHigh);
end;

procedure TAlarmTests.LowThresholdWithHysteresis;
begin
  AssertTransition(Feed('HR', 44, qValid, 60), atRaised, acLow);
  AssertEquals(0, Length(Feed('HR', 49, qValid, 60)));
  AssertTransition(Feed('HR', 50, qValid, 60), atCleared, acLow);
end;

procedure TAlarmTests.OnsetSamplesFilterSpikes;
begin
  AssertEquals(0, Length(Feed('PIP', 40)));
  AssertEquals(0, Length(Feed('PIP', 40)));
  AssertEquals(0, Length(Feed('PIP', 30)));  // resets the onset counter
  AssertEquals(0, Length(Feed('PIP', 40)));
  AssertEquals(0, Length(Feed('PIP', 40)));
  AssertTransition(Feed('PIP', 40), atRaised, acHigh);
end;

procedure TAlarmTests.LatchingHoldsUntilAcknowledged;
var
  A: TActiveAlarms;
begin
  AssertTransition(Feed('SPO2', 86), atRaised, acLow);
  AssertEquals(0, Length(Feed('SPO2', 91)));  // inside hysteresis band
  AssertTransition(Feed('SPO2', 95), atLatched, acLow);
  A := FEngine.ActiveAlarms;
  AssertEquals(1, Length(A));
  AssertEquals('latched', StateNames[A[0].State]);
  AssertEquals(1, FEngine.Acknowledge('BED01', 'SPO2', T0));
  AssertEquals(0, Length(FEngine.ActiveAlarms));
end;

procedure TAlarmTests.AcknowledgeWhileActiveClearsWithoutLatching;
begin
  Feed('SPO2', 86);
  AssertEquals(1, FEngine.Acknowledge('BED01', 'SPO2', T0));
  AssertEquals(0, FEngine.Acknowledge('BED01', 'SPO2', T0));  // already acked
  AssertTransition(Feed('SPO2', 95), atCleared, acLow);
  AssertEquals(0, Length(FEngine.ActiveAlarms));
end;

procedure TAlarmTests.LatchedAlarmRetriggersWithoutSecondRaise;
begin
  Feed('SPO2', 86);
  Feed('SPO2', 95);
  AssertEquals(0, Length(Feed('SPO2', 85)));
  AssertEquals('active', StateNames[FEngine.ActiveAlarms[0].State]);
end;

procedure TAlarmTests.RateOfChangeWithHysteresis;
begin
  Feed('HR', 80, qValid, 60);
  AssertEquals(0, Length(Feed('HR', 100, qValid, 60)));   // 20/min
  AssertEquals(0, Length(Feed('HR', 70, qValid, 60)));    // 30/min, limit is exclusive
  AssertTransition(Feed('HR', 105, qValid, 60), atRaised, acRate);  // 35/min
  AssertEquals(0, Length(Feed('HR', 80, qValid, 60)));    // 25/min, above 20 clear point
  AssertTransition(Feed('HR', 95, qValid, 60), atCleared, acRate);  // 15/min
  // Rate is per minute, not per sample: +10 in 10 s is 60/min.
  AssertTransition(Feed('HR', 105, qValid, 10), atRaised, acRate);
end;

procedure TAlarmTests.RateIgnoresQuestionableSamples;
var
  E: TAlarmEvents;
begin
  Feed('HR', 80, qValid, 60);
  // An artefact of +35 would exceed the rate limit if it entered the history.
  E := Feed('HR', 115, qQuestionable, 60);
  AssertEquals(0, Length(E));
  // Next valid sample is compared with 80, two minutes earlier: 5/min.
  AssertEquals(0, Length(Feed('HR', 90, qValid, 60)));
end;

procedure TAlarmTests.InvalidSamplesDoNotChangeState;
begin
  Feed('SPO2', 86);
  AssertEquals(0, Length(Feed('SPO2', 0, qInvalid)));
  AssertEquals(0, Length(Feed('SPO2', 99, qInvalid)));
  AssertEquals('active', StateNames[FEngine.ActiveAlarms[0].State]);
end;

procedure TAlarmTests.BedsAreIndependent;
var
  E: TAlarmEvents;
begin
  Inc(FT, 10);
  E := FEngine.Process(MakeBatch('BED01', FT, [NumericObs('SPO2', 85)]));
  AssertEquals(1, Length(E));
  E := FEngine.Process(MakeBatch('BED02', FT, [NumericObs('SPO2', 97)]));
  AssertEquals(0, Length(E));
  AssertEquals('BED01', FEngine.ActiveAlarms[0].BedId);
end;

procedure TAlarmTests.PrioritiesPerCondition;
begin
  AssertEquals('medium', PriorityNames[Feed('HR', 130, qValid, 60)[0].Priority]);
  Feed('HR', 100, qValid, 60);
  AssertEquals('high', PriorityNames[Feed('HR', 40, qValid, 600)[0].Priority]);
  AssertEquals('high', PriorityNames[Feed('SPO2', 80)[0].Priority]);
end;

procedure TAlarmTests.AbnormalFlagsReflectActiveState;
var
  F: TAbnormalFlags;
begin
  Feed('SPO2', 85);
  Feed('HR', 125, qValid, 600);
  F := FEngine.AbnormalFlags('BED01');
  AssertEquals(2, Length(F));
  AssertEquals('SPO2', F[0].Code);
  AssertEquals('LL', F[0].Flag);  // high priority low alarm
  AssertEquals('H', F[1].Flag);
  AssertEquals(0, Length(FEngine.AbnormalFlags('BED02')));
end;

procedure TAlarmTests.IniDefaultsAndOverrides;
begin
  FEngine.LoadFromText('[defaults]'#10'Priority=high'#10'Latching=yes'#10 +
    '[TEMP]'#10'HighLimit=38.5'#10'Hysteresis=0.2'#10 +
    '[RR]'#10'HighLimit=30'#10'Latching=off'#10'Priority=low'#10);
  AssertEquals(2, FEngine.RuleCount);
  FT := 0;
  AssertEquals('high', PriorityNames[Feed('TEMP', 38.6)[0].Priority]);
  AssertEquals(0, Length(Feed('TEMP', 38.4)));
  AssertTransition(Feed('TEMP', 38.3), atLatched, acHigh);
  AssertEquals('low', PriorityNames[Feed('RR', 31)[0].Priority]);
  AssertTransition(Feed('RR', 20), atCleared, acHigh);
end;

procedure TAlarmTests.IniRejectsBadConfig;
const
  Bad: array[0..5] of string = (
    '[HR]'#10'HighLimit=abc'#10,
    '[HR]'#10'HighLimit=50'#10'LowLimit=60'#10,
    '[HR]'#10'Hysteresis=5'#10,
    '[HR]'#10'HighLimit=50'#10'Priority=urgent'#10,
    '[HR]'#10'RateLimit=10'#10'RateHysteresis=10'#10,
    '[HR]'#10'HighLimit=50'#10'Latching=maybe'#10);
var
  S: string;
begin
  for S in Bad do
    try
      FEngine.LoadFromText(S);
      Fail('accepted: ' + S);
    except
      on EAlarmConfig do ;
    end;
end;

procedure TAlarmTests.LoadsShippedConfig;
begin
  FEngine.LoadFromFile(ConcatPaths([TestDataDir, 'alarms.ini']));
  AssertEquals(5, FEngine.RuleCount);
end;

initialization
  RegisterTest(TAlarmTests);
end.
