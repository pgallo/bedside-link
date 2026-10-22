{ Driver abstraction. A driver is a push parser: the gateway feeds it raw
  bytes in whatever chunks the transport delivers, and the driver emits one
  TObservationBatch per valid frame. Drivers never touch the transport, so the
  same driver works over a serial port, a TCP terminal server or a recorded
  replay. Concrete drivers register themselves by kind name, which lets the
  gateway build its device list from configuration. }
unit DeviceDriver;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ObsModel;

type
  TParserStats = record
    BytesIn: Int64;
    BytesDiscarded: Int64;  // bytes that never became part of an accepted frame
    FramesOk: Int64;
    ControlFrames: Int64;   // valid frames that carry no observations (heartbeats)
    ChecksumErrors: Int64;
    FramingErrors: Int64;   // structural problems: overflow, unexpected start byte, bad length
    ContentErrors: Int64;   // integrity check passed but payload could not be interpreted
    UnknownParams: Int64;
    SequenceGaps: Int64;    // discontinuities in the device sequence counter
    FramesLost: Int64;      // frames implied missing by those gaps
  end;

  TBatchEvent = procedure(Sender: TObject; const Batch: TObservationBatch) of object;

  TDeviceDriver = class
  private
    FDeviceId: string;
    FBedId: string;
    FOnBatch: TBatchEvent;
    FHaveSeq: Boolean;
    FLastSeq: Cardinal;
  protected
    FStats: TParserStats;
    procedure ProcessByte(B: Byte); virtual; abstract;
    procedure Discard(Count: Integer = 1);
    { Call for every accepted frame, including control frames, so that gaps
      in the device counter reveal frames rejected or lost on the line. }
    procedure TrackSequence(Seq: Cardinal);
    { Fills the identity fields, counts the frame and hands it to OnBatch. }
    procedure Emit(var Batch: TObservationBatch);
  public
    constructor Create(const ADeviceId, ABedId: string); virtual;
    class function Kind: string; virtual; abstract;
    class function Description: string; virtual; abstract;
    procedure Feed(const Buf; Len: Integer);
    procedure FeedStr(const S: AnsiString);
    { Drop any partial frame, e.g. after a transport reconnect. }
    procedure Reset; virtual;
    function StatsSummary: string;
    property DeviceId: string read FDeviceId;
    property BedId: string read FBedId;
    property Stats: TParserStats read FStats;
    property OnBatch: TBatchEvent read FOnBatch write FOnBatch;
  end;

  TDeviceDriverClass = class of TDeviceDriver;

  EDriverError = class(Exception);

procedure RegisterDriver(AClass: TDeviceDriverClass);
function FindDriverClass(const AKind: string): TDeviceDriverClass;
function CreateDriver(const AKind, ADeviceId, ABedId: string): TDeviceDriver;
function RegisteredDriverKinds: TStringArray;

implementation

var
  Registry: array of TDeviceDriverClass;

procedure RegisterDriver(AClass: TDeviceDriverClass);
var
  N: Integer;
begin
  if FindDriverClass(AClass.Kind) <> nil then
    raise EDriverError.CreateFmt('Driver kind "%s" registered twice', [AClass.Kind]);
  N := Length(Registry);
  SetLength(Registry, N + 1);
  Registry[N] := AClass;
end;

function FindDriverClass(const AKind: string): TDeviceDriverClass;
var
  C: TDeviceDriverClass;
begin
  for C in Registry do
    if SameText(C.Kind, AKind) then
      Exit(C);
  Result := nil;
end;

function CreateDriver(const AKind, ADeviceId, ABedId: string): TDeviceDriver;
var
  C: TDeviceDriverClass;
begin
  C := FindDriverClass(AKind);
  if C = nil then
    raise EDriverError.CreateFmt('Unknown driver kind "%s"', [AKind]);
  Result := C.Create(ADeviceId, ABedId);
end;

function RegisteredDriverKinds: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Registry));
  for I := 0 to High(Registry) do
    Result[I] := Registry[I].Kind;
end;

{ TDeviceDriver }

constructor TDeviceDriver.Create(const ADeviceId, ABedId: string);
begin
  inherited Create;
  FDeviceId := ADeviceId;
  FBedId := ABedId;
  FillChar(FStats, SizeOf(FStats), 0);
end;

procedure TDeviceDriver.Discard(Count: Integer);
begin
  Inc(FStats.BytesDiscarded, Count);
end;

procedure TDeviceDriver.TrackSequence(Seq: Cardinal);
begin
  // A counter that goes backwards is treated as a device restart, not a gap.
  if FHaveSeq and (Seq > FLastSeq + 1) then
  begin
    Inc(FStats.SequenceGaps);
    Inc(FStats.FramesLost, Seq - FLastSeq - 1);
  end;
  FHaveSeq := True;
  FLastSeq := Seq;
end;

procedure TDeviceDriver.Emit(var Batch: TObservationBatch);
begin
  TrackSequence(Batch.Sequence);
  Batch.BedId := FBedId;
  Batch.DeviceId := FDeviceId;
  Batch.DeviceKind := Kind;
  Inc(FStats.FramesOk);
  if Assigned(FOnBatch) then
    FOnBatch(Self, Batch);
end;

procedure TDeviceDriver.Feed(const Buf; Len: Integer);
var
  P: PByte;
  I: Integer;
begin
  P := @Buf;
  Inc(FStats.BytesIn, Len);
  for I := 0 to Len - 1 do
    ProcessByte(P[I]);
end;

procedure TDeviceDriver.FeedStr(const S: AnsiString);
begin
  if S <> '' then
    Feed(S[1], Length(S));
end;

procedure TDeviceDriver.Reset;
begin
end;

function TDeviceDriver.StatsSummary: string;
begin
  with FStats do
    Result := Format('bytes=%d ok=%d control=%d crc_err=%d framing_err=%d ' +
      'content_err=%d unknown=%d seq_gaps=%d lost=%d discarded=%d',
      [BytesIn, FramesOk, ControlFrames, ChecksumErrors, FramingErrors,
       ContentErrors, UnknownParams, SequenceGaps, FramesLost, BytesDiscarded]);
end;

end.
