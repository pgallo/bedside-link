{ Shared fixtures: a batch collector for drivers and the data directory
  passed on the test runner command line. }
unit TestHelpers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, ObsModel, DeviceDriver;

type
  TBatchCollector = class
  public
    Batches: array of TObservationBatch;
    procedure OnBatch(Sender: TObject; const Batch: TObservationBatch);
    function Count: Integer;
    procedure Clear;
  end;

var
  TestDataDir: string = 'data';

function T0: TDateTime;
function NumValue(const Batch: TObservationBatch; const Code: string): Double;
function MakeBatch(const Bed: string; Seconds: Integer;
  const Obs: array of TObservation): TObservationBatch;

implementation

procedure TBatchCollector.OnBatch(Sender: TObject; const Batch: TObservationBatch);
var
  N: Integer;
begin
  N := Length(Batches);
  SetLength(Batches, N + 1);
  Batches[N] := Batch;
end;

function TBatchCollector.Count: Integer;
begin
  Result := Length(Batches);
end;

procedure TBatchCollector.Clear;
begin
  Batches := nil;
end;

function T0: TDateTime;
begin
  Result := EncodeDateTime(2026, 10, 20, 8, 0, 0, 0);
end;

function NumValue(const Batch: TObservationBatch; const Code: string): Double;
var
  Obs: TObservation;
begin
  if not FindObservation(Batch, Code, Obs) then
    raise Exception.CreateFmt('observation %s missing', [Code]);
  Result := Obs.Value;
end;

function MakeBatch(const Bed: string; Seconds: Integer;
  const Obs: array of TObservation): TObservationBatch;
var
  I: Integer;
begin
  Result := Default(TObservationBatch);
  Result.BedId := Bed;
  Result.DeviceId := 'TEST';
  Result.DeviceKind := 'test';
  Result.Timestamp := IncSecond(T0, Seconds);
  for I := 0 to High(Obs) do
    AddObservation(Result, Obs[I]);
end;

end.
