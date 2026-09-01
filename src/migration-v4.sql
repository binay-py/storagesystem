-- v4: store when the photo was actually taken (exif / file date), not just uploaded
ALTER TABLE files ADD COLUMN taken_at INTEGER;