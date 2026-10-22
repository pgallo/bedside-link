{ Alarm evaluation over normalised observations.

  Each configured parameter can have three independent conditions:
    high  value above HighLimit, clears at or below HighLimit - Hysteresis
    low   value below LowLimit,  clears at or above LowLimit + Hysteresis
    rate  |delta| per minute above RateLimit, clears below RateLimit - RateHysteresis

  The clear threshold is deliberately offset from the trigger threshold: a
  heart rate oscillating around 120 should produce one alarm, not one alarm
  per sample. Optional OnsetSamples requires the condition to hold for N
  consecutive samples before raising, which filters single-sample spikes.

  Latching: when a latched condition clears it moves to the Latched state and
  stays visible until someone acknowledges it, so a transient desaturation at
  03:00 is still on screen at 03:05. Non-latching alarms clear on their own.

  Invalid samples never change alarm state (a disconnected probe is not a
  normal reading). Questionable samples are evaluated for thresholds but do
  not feed the rate-of-change history, because artefacts produce huge
  spurious slopes. }
unit AlarmEngine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, IniFiles, ObsModel, HL7Encoder;

type
  TAlarmPriority = (apLow, apMedium, apHigh);
  TAlarmCondition = (acHigh, acLow, acRate);
  TAlarmState = (asInactive, asActive, asLatched);
  TAlarmTransition = (atRaised, atCleared, atLatched, atAcknowledged);

  TAlarmRule = record
    Code: string;
    HasHigh, HasLow, HasRate: Boolean;
    HighLimit, LowLimit, Hysteresis: Double;
    RateLimit, RateHysteresis: Double;
    Priority: array[TAlarmCondition] of TAlarmPriority;
    Latching: Boolean;
    OnsetSamples: Integer;
  end;

  TAlarmEvent = record
    BedId: string;
    Code: string;
    Condition: TAlarmCondition;
    Priority: TAlarmPriority;
    Transition: TAlarmTransition;
    Value: Double;      // sample value, or rate per minute for acRate
    Limit: Double;
    Timestamp: TDateTime;
  end;
  TAlarmEvents = array of TAlarmEvent;

  TAlarmEventHandler = procedure(Sender: TObject; const Event: TAlarmEvent) of object;

  TConditionState = record
    State: TAlarmState;
    Acked: Boolean;
    PendingCount: Integer;
  end;

  TTrack = record
    BedId: string;
    Code: string;
    HavePrev: Boolean;
    PrevValue: Double;
    PrevTime: TDateTime;
    Cond: array[TAlarmCondition] of TConditionState;
  end;

  TActiveAlarm = record
    BedId: string;
    Code: string;
    Condition: TAlarmCondition;
    Priority: TAlarmPriority;
    State: TAlarmState;
    Acked: Boolean;
  end;
  TActiveAlarms = array of TActiveAlarm;

  EAlarmConfig = class(Exception);

  TAlarmEngine = class
  private
    FRules: array of TAlarmRule;
    FTracks: array of TTrack;
    FOnEvent: TAlarmEventHandler;
    FPending: TAlarmEvents;
    function RuleIndex(const Code: string): Integer;
    function TrackIndex(const BedId, Code: string; AutoCreate: Boolean): Integer;
    procedure Fire(var Track: TTrack; const Rule: TAlarmRule; C: TAlarmCondition;
      T: TAlarmTransition; Value, Limit: Double; When: TDateTime);
    procedure Evaluate(var Track: TTrack; const Rule: TAlarmRule; C: TAlarmCondition;
      Triggered, Cleared: Boolean; Value, Limit: Double; When: TDateTime);
  public
    procedure Clear;
    procedure AddRule(const Rule: TAlarmRule);
    procedure LoadFromIni(Ini: TCustomIniFile);
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromText(const Text: string);
    { Evaluates every numeric observation in the batch, fires OnEvent for each
      transition and returns them as well. }
    function Process(const Batch: TObservationBatch): TAlarmEvents;
    { Acknowledging a latched alarm clears it; acknowledging an active alarm
      marks it so that it clears without latching. Returns the number of
      conditions affected. }
    function Acknowledge(const BedId, Code: string; When: TDateTime): Integer;
    function ActiveAlarms: TActiveAlarms;
    { HL7 OBX-8 flags for the current state of a bed: H/L for threshold
      alarms (HH/LL at high priority), A for rate-of-change only. }
    function AbnormalFlags(const BedId: string): TAbnormalFlags;
    function RuleCount: Integer;
    property OnEvent: TAlarmEventHandler read FOnEvent write FOnEvent;
  end;

const
  PriorityNames: array[TAlarmPriority] of string = ('low', 'medium', 'high');
  ConditionNames: array[TAlarmCondition] of string = ('high', 'low', 'rate');
  TransitionNames: array[TAlarmTransition] of string =
    ('RAISED', 'CLEARED', 'LATCHED', 'ACKED');
  StateNames: array[TAlarmState] of string = ('inactive', 'active', 'latched');

function ParsePriority(const S: string; out P: TAlarmPriority): Boolean;
function NewRule(const Code: string): TAlarmRule;
function FormatAlarmEvent(const E: TAlarmEvent): string;

implementation

function ParsePriority(const S: string; out P: TAlarmPriority): Boolean;
var
  I: TAlarmPriority;
begin
  for I := Low(TAlarmPriority) to High(TAlarmPriority) do
    if SameText(S, PriorityNames[I]) then
    begin
      P := I;
      Exit(True);
    end;
  P := apMedium;
  Result := False;
end;

function NewRule(const Code: string): TAlarmRule;
var
  C: TAlarmCondition;
begin
  Result := Default(TAlarmRule);
  Result.Code := Code;
  for C := Low(TAlarmCondition) to High(TAlarmCondition) do
    Result.Priority[C] := apMedium;
  Result.OnsetSamples := 1;
end;

function FormatAlarmEvent(const E: TAlarmEvent): string;
const
  Units: array[TAlarmCondition] of string = ('', '', '/min');
begin
  Result := Format('%-7s %-6s %-5s %-6s %-4s value=%s%s limit=%s',
    [TransitionNames[E.Transition], E.BedId, E.Code, PriorityNames[E.Priority],
     ConditionNames[E.Condition],
     FloatToStrF(E.Value, ffFixed, 15, 1, InvariantFS), Units[E.Condition],
     FloatToStrF(E.Limit, ffFixed, 15, 1, InvariantFS)]);
end;

{ TAlarmEngine }

procedure TAlarmEngine.Clear;
begin
  FRules := nil;
  FTracks := nil;
end;

function TAlarmEngine.RuleCount: Integer;
begin
  Result := Length(FRules);
end;

function TAlarmEngine.RuleIndex(const Code: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRules) do
    if FRules[I].Code = Code then
      Exit(I);
  Result := -1;
end;

procedure TAlarmEngine.AddRule(const Rule: TAlarmRule);
var
  I: Integer;
begin
  if Rule.HasHigh and Rule.HasLow and (Rule.LowLimit >= Rule.HighLimit) then
    raise EAlarmConfig.CreateFmt('%s: LowLimit must be below HighLimit', [Rule.Code]);
  if Rule.Hysteresis < 0 then
    raise EAlarmConfig.CreateFmt('%s: Hysteresis must not be negative', [Rule.Code]);
  if Rule.HasRate and ((Rule.RateLimit <= 0) or (Rule.RateHysteresis < 0) or
     (Rule.RateHysteresis >= Rule.RateLimit)) then
    raise EAlarmConfig.CreateFmt('%s: need RateLimit > RateHysteresis >= 0', [Rule.Code]);
  if Rule.OnsetSamples < 1 then
    raise EAlarmConfig.CreateFmt('%s: OnsetSamples must be >= 1', [Rule.Code]);
  I := RuleIndex(Rule.Code);
  if I < 0 then
  begin
    I := Length(FRules);
    SetLength(FRules, I + 1);
  end;
  FRules[I] := Rule;
end;

procedure TAlarmEngine.LoadFromIni(Ini: TCustomIniFile);
var
  Sections: TStringList;
  Section: string;
  Rule: TAlarmRule;
  DefPrio: TAlarmPriority;
  DefLatching: Boolean;
  C: TAlarmCondition;

  function ReadNum(const Key: string; out V: Double): Boolean;
  var
    S: string;
  begin
    S := Trim(Ini.ReadString(Section, Key, ''));
    Result := S <> '';
    if Result and not ParseFloatInv(S, V) then
      raise EAlarmConfig.CreateFmt('[%s] %s: "%s" is not a number', [Section, Key, S]);
  end;

  function ReadPrio(const Key: string; Fallback: TAlarmPriority): TAlarmPriority;
  var
    S: string;
  begin
    S := Trim(Ini.ReadString(Section, Key, ''));
    if S = '' then
      Exit(Fallback);
    if not ParsePriority(S, Result) then
      raise EAlarmConfig.CreateFmt('[%s] %s: unknown priority "%s"', [Section, Key, S]);
  end;

  // TCustomIniFile.ReadBool only recognises '1'; accept the usual spellings
  // and reject anything else instead of silently reading it as false.
  function ReadFlag(const Key: string; Fallback: Boolean): Boolean;
  var
    S: string;
  begin
    S := LowerCase(Trim(Ini.ReadString(Section, Key, '')));
    if S = '' then
      Result := Fallback
    else if (S = '1') or (S = 'true') or (S = 'yes') or (S = 'on') then
      Result := True
    else if (S = '0') or (S = 'false') or (S = 'no') or (S = 'off') then
      Result := False
    else
      raise EAlarmConfig.CreateFmt('[%s] %s: "%s" is not a boolean', [Section, Key, S]);
  end;

begin
  Clear;
  Sections := TStringList.Create;
  try
    Ini.ReadSections(Sections);
    Section := 'defaults';
    DefLatching := ReadFlag('Latching', False);
    DefPrio := ReadPrio('Priority', apMedium);
    for Section in Sections do
    begin
      if SameText(Section, 'defaults') then
        Continue;
      Rule := NewRule(UpperCase(Section));
      Rule.HasHigh := ReadNum('HighLimit', Rule.HighLimit);
      Rule.HasLow := ReadNum('LowLimit', Rule.LowLimit);
      Rule.HasRate := ReadNum('RateLimit', Rule.RateLimit);
      ReadNum('Hysteresis', Rule.Hysteresis);
      ReadNum('RateHysteresis', Rule.RateHysteresis);
      Rule.Latching := ReadFlag('Latching', DefLatching);
      Rule.OnsetSamples := Ini.ReadInteger(Section, 'OnsetSamples', 1);
      for C := Low(TAlarmCondition) to High(TAlarmCondition) do
        Rule.Priority[C] := ReadPrio('Priority', DefPrio);
      Rule.Priority[acHigh] := ReadPrio('HighPriority', Rule.Priority[acHigh]);
      Rule.Priority[acLow] := ReadPrio('LowPriority', Rule.Priority[acLow]);
      Rule.Priority[acRate] := ReadPrio('RatePriority', Rule.Priority[acRate]);
      if not (Rule.HasHigh or Rule.HasLow or Rule.HasRate) then
        raise EAlarmConfig.CreateFmt('[%s] defines no limit', [Section]);
      AddRule(Rule);
    end;
  finally
    Sections.Free;
  end;
end;

procedure TAlarmEngine.LoadFromFile(const FileName: string);
var
  Ini: TMemIniFile;
begin
  if not FileExists(FileName) then
    raise EAlarmConfig.CreateFmt('Alarm configuration not found: %s', [FileName]);
  Ini := TMemIniFile.Create(FileName);
  try
    LoadFromIni(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TAlarmEngine.LoadFromText(const Text: string);
var
  Ini: TMemIniFile;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  Ini := TMemIniFile.Create('');
  try
    Lines.Text := Text;
    Ini.SetStrings(Lines);
    LoadFromIni(Ini);
  finally
    Ini.Free;
    Lines.Free;
  end;
end;

function TAlarmEngine.TrackIndex(const BedId, Code: string; AutoCreate: Boolean): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FTracks) do
    if (FTracks[I].BedId = BedId) and (FTracks[I].Code = Code) then
      Exit(I);
  if not AutoCreate then
    Exit(-1);
  Result := Length(FTracks);
  SetLength(FTracks, Result + 1);
  FTracks[Result] := Default(TTrack);
  FTracks[Result].BedId := BedId;
  FTracks[Result].Code := Code;
end;

procedure TAlarmEngine.Fire(var Track: TTrack; const Rule: TAlarmRule;
  C: TAlarmCondition; T: TAlarmTransition; Value, Limit: Double; When: TDateTime);
var
  E: TAlarmEvent;
  N: Integer;
begin
  E.BedId := Track.BedId;
  E.Code := Track.Code;
  E.Condition := C;
  E.Priority := Rule.Priority[C];
  E.Transition := T;
  E.Value := Value;
  E.Limit := Limit;
  E.Timestamp := When;
  N := Length(FPending);
  SetLength(FPending, N + 1);
  FPending[N] := E;
  if Assigned(FOnEvent) then
    FOnEvent(Self, E);
end;

procedure TAlarmEngine.Evaluate(var Track: TTrack; const Rule: TAlarmRule;
  C: TAlarmCondition; Triggered, Cleared: Boolean; Value, Limit: Double; When: TDateTime);
begin
  with Track.Cond[C] do
    case State of
      asInactive, asLatched:
        if Triggered then
        begin
          Inc(PendingCount);
          if PendingCount >= Rule.OnsetSamples then
          begin
            // A latched alarm that re-triggers becomes active again; it is
            // still the same unacknowledged alarm, so no second RAISED.
            if State = asInactive then
              Fire(Track, Rule, C, atRaised, Value, Limit, When);
            State := asActive;
            Acked := False;
            PendingCount := 0;
          end;
        end
        else
          PendingCount := 0;
      asActive:
        if Cleared then
        begin
          PendingCount := 0;
          if Rule.Latching and not Acked then
          begin
            State := asLatched;
            Fire(Track, Rule, C, atLatched, Value, Limit, When);
          end
          else
          begin
            State := asInactive;
            Acked := False;
            Fire(Track, Rule, C, atCleared, Value, Limit, When);
          end;
        end;
    end;
end;

function TAlarmEngine.Process(const Batch: TObservationBatch): TAlarmEvents;
var
  Obs: TObservation;
  RI, TI: Integer;
  Rule: TAlarmRule;
  V, DtMin, Rate: Double;
begin
  FPending := nil;
  for Obs in Batch.Observations do
  begin
    if (Obs.Kind <> vkNumeric) or (Obs.Quality = qInvalid) then
      Continue;
    RI := RuleIndex(Obs.Code);
    if RI < 0 then
      Continue;
    Rule := FRules[RI];
    TI := TrackIndex(Batch.BedId, Obs.Code, True);
    V := Obs.Value;

    if Rule.HasHigh then
      Evaluate(FTracks[TI], Rule, acHigh, V > Rule.HighLimit,
        V <= Rule.HighLimit - Rule.Hysteresis, V, Rule.HighLimit, Batch.Timestamp);
    if Rule.HasLow then
      Evaluate(FTracks[TI], Rule, acLow, V < Rule.LowLimit,
        V >= Rule.LowLimit + Rule.Hysteresis, V, Rule.LowLimit, Batch.Timestamp);

    if Rule.HasRate and (Obs.Quality = qValid) then
    begin
      with FTracks[TI] do
        if HavePrev then
        begin
          DtMin := (Batch.Timestamp - PrevTime) * 24 * 60;
          if DtMin > 0 then
          begin
            Rate := Abs(V - PrevValue) / DtMin;
            Evaluate(FTracks[TI], Rule, acRate, Rate > Rule.RateLimit,
              Rate < Rule.RateLimit - Rule.RateHysteresis, Rate, Rule.RateLimit,
              Batch.Timestamp);
          end;
        end;
      FTracks[TI].HavePrev := True;
      FTracks[TI].PrevValue := V;
      FTracks[TI].PrevTime := Batch.Timestamp;
    end;
  end;
  Result := FPending;
  FPending := nil;
end;

function TAlarmEngine.Acknowledge(const BedId, Code: string; When: TDateTime): Integer;
var
  TI, RI: Integer;
  C: TAlarmCondition;
begin
  Result := 0;
  FPending := nil;
  TI := TrackIndex(BedId, Code, False);
  RI := RuleIndex(Code);
  if (TI < 0) or (RI < 0) then
    Exit;
  for C := Low(TAlarmCondition) to High(TAlarmCondition) do
    with FTracks[TI].Cond[C] do
      case State of
        asLatched:
          begin
            State := asInactive;
            Fire(FTracks[TI], FRules[RI], C, atAcknowledged, 0, 0, When);
            Inc(Result);
          end;
        asActive:
          if not Acked then
          begin
            Acked := True;
            Fire(FTracks[TI], FRules[RI], C, atAcknowledged, 0, 0, When);
            Inc(Result);
          end;
      end;
  FPending := nil;
end;

function TAlarmEngine.ActiveAlarms: TActiveAlarms;
var
  I, N, RI: Integer;
  C: TAlarmCondition;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(FTracks) do
    for C := Low(TAlarmCondition) to High(TAlarmCondition) do
      if FTracks[I].Cond[C].State <> asInactive then
      begin
        RI := RuleIndex(FTracks[I].Code);
        SetLength(Result, N + 1);
        Result[N].BedId := FTracks[I].BedId;
        Result[N].Code := FTracks[I].Code;
        Result[N].Condition := C;
        Result[N].Priority := FRules[RI].Priority[C];
        Result[N].State := FTracks[I].Cond[C].State;
        Result[N].Acked := FTracks[I].Cond[C].Acked;
        Inc(N);
      end;
end;

function TAlarmEngine.AbnormalFlags(const BedId: string): TAbnormalFlags;
var
  I, N, RI: Integer;
  F: string;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(FTracks) do
  begin
    if FTracks[I].BedId <> BedId then
      Continue;
    RI := RuleIndex(FTracks[I].Code);
    F := '';
    with FTracks[I] do
      if Cond[acHigh].State = asActive then
      begin
        F := 'H';
        if FRules[RI].Priority[acHigh] = apHigh then F := 'HH';
      end
      else if Cond[acLow].State = asActive then
      begin
        F := 'L';
        if FRules[RI].Priority[acLow] = apHigh then F := 'LL';
      end
      else if Cond[acRate].State = asActive then
        F := 'A';
    if F <> '' then
    begin
      SetLength(Result, N + 1);
      Result[N].Code := FTracks[I].Code;
      Result[N].Flag := F;
      Inc(N);
    end;
  end;
end;

end.
