-- =====================================================================
-- Expo Village Tracker. Clear test data before go-live.
-- Deletes ALL requests, request history and room change history, and
-- restarts request IDs at EXV-0001. Staff, rooms and lookups stay.
-- There is no undo. Export the CSVs first if you want to keep anything.
-- =====================================================================

begin;
truncate public.request_events, public.room_log, public.requests restart identity;
alter sequence public.request_seq restart with 1;

-- Optional: remove rooms the loader marked inactive (test rooms that are
-- not in the real room list). Only works once no requests point at them,
-- which is true straight after the truncate above.
-- delete from public.rooms where not active;

-- Optional: set every room to a known starting state for day one.
-- update public.rooms set status = 'dirty', status_at = now(), status_by = 'SETUP';
commit;

-- Photos are not deleted by this script. Remove them in
-- Storage > request-photos (select all folders > Delete).
