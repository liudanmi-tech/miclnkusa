-- Migration: add emoji_type column to profiles table
-- Run once on server: psql -U postgres -d <dbname> -f add_emoji_type.sql

ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS emoji_type VARCHAR(50) DEFAULT 'self';
