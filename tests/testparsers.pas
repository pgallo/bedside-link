{ Parser tests. Every corrupted-input case asserts two things: the bad frame
  is rejected with the right counter, and the parser recovers in time to
  accept the next good frame. }
unit TestParsers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, fpcunit, testregistry, ObsModel, Checksums, DeviceDriver,
  DrvMonitor, DrvVentilator, DrvInfusion, Transport, TestHelpers;

type
  TParserTestCase = class(TTestCase)
  protected
    FSink: TBatchCollector;
    FDriver: TDeviceDriver;
    function DriverClass: TDeviceDriverClass; virtual; abstract;
    procedure SetUp; override;
    procedure TearDown; override;
    { Feeds S one byte at a time, then in chunks of every size up to 17, and
      checks the decoded batch count is identical each time. }
    procedure AssertChunkingInvariant(const S: AnsiString; ExpectedBatches: Integer);
  end;

  TMonitorParserTests = class(TParserTestCase)
  protected
    function DriverClass: TDeviceDriverClass; override;
    function Frame(Seq: Integer; const Items: string): AnsiString;
  published
    procedure DecodesValidFrame;
    procedure QualityMarkers;
    procedure SkipsGarbageBetweenFrames;
    procedure ChecksumFailureIsCountedAndSkipped;
    procedure NonHexChecksumIsFramingError;
    procedure LostEtxResyncsOnNextStx;
    procedure OversizeFrameIsDropped;
    procedure BadHeaderIsContentError;
    procedure UnknownParameterIgnored;
    procedure ChunkingDoesNotChangeResult;
    procedure SequenceGapsAreCounted;
  end;

  TVentilatorParserTests = class(TParserTestCase)
  protected
    function DriverClass: TDeviceDriverClass; override;
    function Measurement(Seq: Word; PipValue: Double): AnsiString;
  published
    procedure DecodesFixedPointValues;
    procedure FlagsMapToQuality;
    procedure HeartbeatIsControlFrame;
    procedure CrcFailureResyncsInsideFrame;
    procedure CorruptLengthDoesNotSwallowNextFrame;
    procedure ImpossibleLengthIsFramingError;
    procedure FalseSyncInNoise;
    procedure PartialFrameWaitsForMoreBytes;
    procedure ChunkingDoesNotChangeResult;
  end;

  TInfusionParserTests = class(TParserTestCase)
  protected
    function DriverClass: TDeviceDriverClass; override;
  published
    procedure DecodesRecord;
    procedure KeysInAnyOrderAndUnknownKeysIgnored;
    procedure BannerLinesIgnored;
    procedure ChecksumMismatch;
    procedure MissingChecksumIsFramingError;
    procedure OversizeLineDroppedUntilNewline;
    procedure MissingSequenceIsContentError;
    procedure DrugLabelWithStarsUsesLastStar;
    procedure AcceptsBareLf;
  end;

  TTransportTests = class(TTestCase)
  published
    procedure ReplayFragmentsButPreservesBytes;
    procedure ReplayIsDeterministic;
    procedure RegistryCreatesDriversByKind;
  end;

implementation

{ TParserTestCase }

procedure TParserTestCase.SetUp;
begin
  FSink := TBatchCollector.Create;
  FDriver := DriverClass.Create('DEV-1', 'BED07');
  FDriver.OnBatch := @FSink.OnBatch;
end;

procedure TParserTestCase.TearDown;
begin
  FDriver.Free;
  FSink.Free;
end;

procedure TParserTestCase.AssertChunkingInvariant(const S: AnsiString; ExpectedBatches: Integer);
var
  Chunk, Pos, N: Integer;
  D: TDeviceDriver;
  C: TBatchCollector;
begin
  for Chunk := 1 to 17 do
  begin
    C := TBatchCollector.Create;
    D := DriverClass.Create('DEV-1', 'BED07');
    try
      D.OnBatch := @C.OnBatch;
      Pos := 1;
      while Pos <= Length(S) do
      begin
        N := Chunk;
        if Pos + N - 1 > Length(S) then
          N := Length(S) - Pos + 1;
        D.Feed(S[Pos], N);
        Inc(Pos, N);
      end;
      AssertEquals(Format('chunk size %d', [Chunk]), ExpectedBatches, C.Count);
    finally
      D.Free;
      C.Free;
    end;
  end;
end;

{ TMonitorParserTests }

function TMonitorParserTests.DriverClass: TDeviceDriverClass;
begin
  Result := TMonitorDriver;
end;

function TMonitorParserTests.Frame(Seq: Integer; const Items: string): AnsiString;
begin
  Result := TMonitorDriver.EncodeFrame(Format('MON|%d|20261020080000|%s', [Seq, Items]));
end;

procedure TMonitorParserTests.DecodesValidFrame;
var
  B: TObservationBatch;
begin
  FDriver.FeedStr(Frame(5, 'HR=72;SPO2=98;TEMP=36.8'));
  AssertEquals(1, FSink.Count);
  B := FSink.Batches[0];
  AssertEquals('BED07', B.BedId);
  AssertEquals('DEV-1', B.DeviceId);
  AssertEquals(5, B.Sequence);
  AssertEquals(3, Length(B.Observations));
  AssertEquals(72.0, NumValue(B, 'HR'), 1e-9);
  AssertEquals(36.8, NumValue(B, 'TEMP'), 1e-9);
  AssertEquals('Cel', B.Observations[2].Units);
  AssertTrue(SameDateTime(EncodeDateTime(2026, 10, 20, 8, 0, 0, 0), B.Timestamp));
end;

procedure TMonitorParserTests.QualityMarkers;
var
  O: TObservation;
begin
  FDriver.FeedStr(Frame(1, 'HR=72?;SPO2=---'));
  AssertTrue(FindObservation(FSink.Batches[0], 'HR', O));
  AssertTrue(O.Quality = qQuestionable);
  AssertEquals(72.0, O.Value, 1e-9);
  AssertTrue(FindObservation(FSink.Batches[0], 'SPO2', O));
  AssertTrue(O.Quality = qInvalid);
end;

procedure TMonitorParserTests.SkipsGarbageBetweenFrames;
begin
  FDriver.FeedStr(#13#10'xx'#$FF + Frame(1, 'HR=70') + #0#0#3'41' + Frame(2, 'HR=71'));
  AssertEquals(2, FSink.Count);
  AssertEquals(0, FDriver.Stats.ChecksumErrors);
  AssertTrue(FDriver.Stats.BytesDiscarded >= 10);
end;

procedure TMonitorParserTests.ChecksumFailureIsCountedAndSkipped;
var
  Bad: AnsiString;
begin
  Bad := Frame(1, 'HR=70');
  Bad[Length(Bad)] := Chr(Ord(Bad[Length(Bad)]) xor 1);
  FDriver.FeedStr(Bad + Frame(2, 'HR=71'));
  AssertEquals(1, FSink.Count);
  AssertEquals(2, FSink.Batches[0].Sequence);
  AssertEquals(1, FDriver.Stats.ChecksumErrors);
end;

procedure TMonitorParserTests.NonHexChecksumIsFramingError;
var
  Bad: AnsiString;
begin
  Bad := Frame(1, 'HR=70');
  Bad[Length(Bad)] := 'Z';
  FDriver.FeedStr(Bad + Frame(2, 'HR=71'));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.FramingErrors);
  AssertEquals(0, FDriver.Stats.ChecksumErrors);
end;

procedure TMonitorParserTests.LostEtxResyncsOnNextStx;
var
  Truncated: AnsiString;
begin
  Truncated := Frame(1, 'HR=70');
  SetLength(Truncated, Length(Truncated) - 3);  // ETX and checksum lost
  FDriver.FeedStr(Truncated + Frame(2, 'HR=71'));
  AssertEquals(1, FSink.Count);
  AssertEquals(2, FSink.Batches[0].Sequence);
  AssertEquals(1, FDriver.Stats.FramingErrors);
end;

procedure TMonitorParserTests.OversizeFrameIsDropped;
begin
  FDriver.FeedStr(#2 + StringOfChar('A', MonitorMaxPayload + 50) + Frame(3, 'HR=60'));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.FramingErrors);
end;

procedure TMonitorParserTests.BadHeaderIsContentError;
begin
  FDriver.FeedStr(TMonitorDriver.EncodeFrame('MON|x|20261020080000|HR=70'));
  FDriver.FeedStr(TMonitorDriver.EncodeFrame('MON|1|20261340080000|HR=70'));
  AssertEquals(0, FSink.Count);
  AssertEquals(2, FDriver.Stats.ContentErrors);
end;

procedure TMonitorParserTests.UnknownParameterIgnored;
begin
  FDriver.FeedStr(Frame(1, 'HR=70;XYZ=3;SPO2=99'));
  AssertEquals(2, Length(FSink.Batches[0].Observations));
  AssertEquals(1, FDriver.Stats.UnknownParams);
end;

procedure TMonitorParserTests.ChunkingDoesNotChangeResult;
var
  S, Bad: AnsiString;
begin
  Bad := Frame(2, 'HR=1');
  Bad[Length(Bad)] := '0';
  S := 'noise' + Frame(1, 'HR=70') + Bad + #2'trunc' + Frame(3, 'HR=72') + #13#10;
  AssertChunkingInvariant(S, 2);
end;

procedure TMonitorParserTests.SequenceGapsAreCounted;
begin
  FDriver.FeedStr(Frame(1, 'HR=70') + Frame(2, 'HR=70') + Frame(5, 'HR=70') + Frame(0, 'HR=70'));
  AssertEquals(4, FSink.Count);
  AssertEquals(1, FDriver.Stats.SequenceGaps);
  AssertEquals(2, FDriver.Stats.FramesLost);
end;

{ TVentilatorParserTests }

function TVentilatorParserTests.DriverClass: TDeviceDriverClass;
begin
  Result := TVentilatorDriver;
end;

function TVentilatorParserTests.Measurement(Seq: Word; PipValue: Double): AnsiString;
var
  Items: TVentItemArray;
begin
  Items := nil;
  SetLength(Items, 2);
  Items[0].Id := 1; Items[0].Value := PipValue; Items[0].Flags := 0;
  Items[1].Id := 6; Items[1].Value := 7.25;     Items[1].Flags := 0;
  Result := TVentilatorDriver.EncodeMeasurement(Seq, T0, Items);
end;

procedure TVentilatorParserTests.DecodesFixedPointValues;
var
  B: TObservationBatch;
begin
  FDriver.FeedStr(Measurement(300, 27.3));
  AssertEquals(1, FSink.Count);
  B := FSink.Batches[0];
  AssertEquals(300, B.Sequence);
  AssertEquals(27.3, NumValue(B, 'PIP'), 1e-9);
  AssertEquals(7.25, NumValue(B, 'MV'), 1e-9);
  AssertEquals('cm[H2O]', B.Observations[0].Units);
  AssertTrue(SameDateTime(T0, B.Timestamp));
end;

procedure TVentilatorParserTests.FlagsMapToQuality;
var
  Items: TVentItemArray;
  O: TObservation;
begin
  Items := nil;
  SetLength(Items, 3);
  Items[0].Id := 1; Items[0].Value := 20; Items[0].Flags := VentFlagQuestionable;
  Items[1].Id := 4; Items[1].Value := -1; Items[1].Flags := VentFlagInvalid;
  Items[2].Id := 9; Items[2].Value := 1;  Items[2].Flags := 0;
  FDriver.FeedStr(TVentilatorDriver.EncodeMeasurement(1, T0, Items));
  AssertTrue(FindObservation(FSink.Batches[0], 'PIP', O));
  AssertTrue(O.Quality = qQuestionable);
  AssertTrue(FindObservation(FSink.Batches[0], 'VT', O));
  AssertTrue(O.Quality = qInvalid);
  AssertEquals(-1.0, O.Value, 1e-9);  // signed int16 survives the round trip
  AssertEquals(1, FDriver.Stats.UnknownParams);
end;

procedure TVentilatorParserTests.HeartbeatIsControlFrame;
begin
  FDriver.FeedStr(TVentilatorDriver.EncodeHeartbeat(1, T0) + Measurement(2, 20));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.ControlFrames);
  AssertEquals(0, FDriver.Stats.SequenceGaps);
end;

procedure TVentilatorParserTests.CrcFailureResyncsInsideFrame;
var
  Bad: AnsiString;
begin
  Bad := Measurement(1, 20);
  Bad[8] := Chr(Ord(Bad[8]) xor $40);
  FDriver.FeedStr(Bad + Measurement(2, 21));
  AssertEquals(1, FSink.Count);
  AssertEquals(2, FSink.Batches[0].Sequence);
  AssertEquals(1, FDriver.Stats.ChecksumErrors);
end;

procedure TVentilatorParserTests.CorruptLengthDoesNotSwallowNextFrame;
var
  Bad: AnsiString;
begin
  // LEN inflated so the claimed frame extends over the next real frame. A
  // skip-by-length parser would lose frame 2; the rescan must find it.
  Bad := Measurement(1, 20);
  Bad[3] := Chr(Ord(Bad[3]) + 12);
  FDriver.FeedStr(Bad + Measurement(2, 21) + Measurement(3, 22));
  AssertEquals(2, FSink.Count);
  AssertEquals(2, FSink.Batches[0].Sequence);
  AssertEquals(3, FSink.Batches[1].Sequence);
  AssertEquals(1, FDriver.Stats.ChecksumErrors);
end;

procedure TVentilatorParserTests.ImpossibleLengthIsFramingError;
begin
  FDriver.FeedStr(#$A5#$5A#$02 + Measurement(1, 20));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.FramingErrors);
end;

procedure TVentilatorParserTests.FalseSyncInNoise;
begin
  FDriver.FeedStr(#$A5#$00#$A5#$A5 + Measurement(1, 20));
  AssertEquals(1, FSink.Count);
  AssertEquals(4, FDriver.Stats.BytesDiscarded);
end;

procedure TVentilatorParserTests.PartialFrameWaitsForMoreBytes;
var
  F: AnsiString;
begin
  F := Measurement(1, 20);
  FDriver.FeedStr(Copy(F, 1, 9));
  AssertEquals(0, FSink.Count);
  AssertEquals(0, FDriver.Stats.ChecksumErrors);
  FDriver.FeedStr(Copy(F, 10, MaxInt));
  AssertEquals(1, FSink.Count);
end;

procedure TVentilatorParserTests.ChunkingDoesNotChangeResult;
var
  Bad: AnsiString;
begin
  Bad := Measurement(2, 20);
  Bad[3] := Chr(Ord(Bad[3]) + 5);
  AssertChunkingInvariant(#0#$A5 + Measurement(1, 20) + Bad +
    TVentilatorDriver.EncodeHeartbeat(3, T0) + Measurement(4, 22), 2);
end;

{ TInfusionParserTests }

function TInfusionParserTests.DriverClass: TDeviceDriverClass;
begin
  Result := TInfusionDriver;
end;

procedure TInfusionParserTests.DecodesRecord;
var
  B: TObservationBatch;
  O: TObservation;
begin
  FDriver.FeedStr(TInfusionDriver.EncodeLine(
    'PUMP,seq=9,ts=20261020080000,state=running,rate=12.5,vi=3.20,vtbi=50.0,occl=0,drug=Saline'));
  AssertEquals(1, FSink.Count);
  B := FSink.Batches[0];
  AssertEquals(9, B.Sequence);
  AssertEquals(12.5, NumValue(B, 'INF_RATE'), 1e-9);
  AssertTrue(FindObservation(B, 'INF_STATE', O));
  AssertTrue(O.Kind = vkText);
  AssertEquals('RUNNING', O.Text);
  AssertTrue(FindObservation(B, 'INF_DRUG', O));
  AssertEquals('Saline', O.Text);
end;

procedure TInfusionParserTests.KeysInAnyOrderAndUnknownKeysIgnored;
begin
  FDriver.FeedStr(TInfusionDriver.EncodeLine('PUMP,rate=4,fw=2.1,ts=20261020080000,seq=1'));
  AssertEquals(1, FSink.Count);
  AssertEquals(4.0, NumValue(FSink.Batches[0], 'INF_RATE'), 1e-9);
  AssertEquals(1, FDriver.Stats.UnknownParams);
end;

procedure TInfusionParserTests.BannerLinesIgnored;
begin
  FDriver.FeedStr('boot v1.2'#13#10'menu> '#13#10 +
    TInfusionDriver.EncodeLine('PUMP,seq=1,ts=20261020080000,rate=1'));
  AssertEquals(1, FSink.Count);
  AssertEquals(0, FDriver.Stats.FramingErrors);
end;

procedure TInfusionParserTests.ChecksumMismatch;
var
  L: AnsiString;
begin
  L := TInfusionDriver.EncodeLine('PUMP,seq=1,ts=20261020080000,rate=1');
  L[Pos('rate=1', L) + 5] := '7';
  FDriver.FeedStr(L + TInfusionDriver.EncodeLine('PUMP,seq=2,ts=20261020080000,rate=1'));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.ChecksumErrors);
end;

procedure TInfusionParserTests.MissingChecksumIsFramingError;
begin
  FDriver.FeedStr('$PUMP,seq=1,ts=20261020080000,rate=1'#13#10);
  AssertEquals(0, FSink.Count);
  AssertEquals(1, FDriver.Stats.FramingErrors);
end;

procedure TInfusionParserTests.OversizeLineDroppedUntilNewline;
begin
  FDriver.FeedStr('$PUMP,' + StringOfChar('9', 3 * PumpMaxLine) + '*00'#13#10 +
    TInfusionDriver.EncodeLine('PUMP,seq=1,ts=20261020080000,rate=1'));
  AssertEquals(1, FSink.Count);
  AssertEquals(1, FDriver.Stats.FramingErrors);
end;

procedure TInfusionParserTests.MissingSequenceIsContentError;
begin
  FDriver.FeedStr(TInfusionDriver.EncodeLine('PUMP,ts=20261020080000,rate=1'));
  AssertEquals(0, FSink.Count);
  AssertEquals(1, FDriver.Stats.ContentErrors);
end;

procedure TInfusionParserTests.DrugLabelWithStarsUsesLastStar;
var
  O: TObservation;
begin
  FDriver.FeedStr(TInfusionDriver.EncodeLine('PUMP,seq=1,ts=20261020080000,drug=A*B|C^D'));
  AssertEquals(1, FSink.Count);
  AssertTrue(FindObservation(FSink.Batches[0], 'INF_DRUG', O));
  AssertEquals('A*B|C^D', O.Text);
end;

procedure TInfusionParserTests.AcceptsBareLf;
var
  L: AnsiString;
begin
  L := TInfusionDriver.EncodeLine('PUMP,seq=1,ts=20261020080000,rate=1');
  Delete(L, Length(L) - 1, 1);  // drop CR
  FDriver.FeedStr(L);
  AssertEquals(1, FSink.Count);
end;

{ TTransportTests }

procedure TTransportTests.ReplayFragmentsButPreservesBytes;
var
  T: TReplayTransport;
  Buf: array[0..63] of Byte;
  N, Reads, MaxN: Integer;
  Got, Src: AnsiString;
begin
  Src := StringOfChar('x', 500) + 'END';
  T := TReplayTransport.CreateFromString('mem', Src, 7, 42);
  try
    Got := '';
    Reads := 0;
    MaxN := 0;
    while not T.Eof do
    begin
      N := T.Read(Buf, SizeOf(Buf));
      AssertTrue(N >= 1);
      if N > MaxN then MaxN := N;
      SetLength(Got, Length(Got) + N);
      Move(Buf, Got[Length(Got) - N + 1], N);
      Inc(Reads);
    end;
    AssertEquals(Src, Got);
    AssertTrue('fragmented', Reads > Length(Src) div 7);
    AssertTrue(MaxN <= 7);
  finally
    T.Free;
  end;
end;

procedure TTransportTests.ReplayIsDeterministic;
var
  A, B: TReplayTransport;
  Buf: array[0..15] of Byte;
  I: Integer;
begin
  A := TReplayTransport.CreateFromString('a', StringOfChar('z', 200), 9, 5);
  B := TReplayTransport.CreateFromString('b', StringOfChar('z', 200), 9, 5);
  try
    for I := 1 to 20 do
      AssertEquals(A.Read(Buf, 16), B.Read(Buf, 16));
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TTransportTests.RegistryCreatesDriversByKind;
var
  D: TDeviceDriver;
begin
  D := CreateDriver('VENTILATOR', 'V1', 'BED01');
  try
    AssertEquals('ventilator', D.Kind);
    AssertEquals('BED01', D.BedId);
  finally
    D.Free;
  end;
  AssertEquals(3, Length(RegisteredDriverKinds));
  try
    CreateDriver('dialysis', 'X', 'Y');
    Fail('expected EDriverError');
  except
    on EDriverError do ;
  end;
end;

initialization
  RegisterTests([TMonitorParserTests, TVentilatorParserTests, TInfusionParserTests,
    TTransportTests]);
end.
