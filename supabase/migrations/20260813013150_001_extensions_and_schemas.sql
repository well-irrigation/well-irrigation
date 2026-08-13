-- تفعيل اداة توليد معرفات UUID فريدة لكل سجل
create extension if not exists "pgcrypto";

-- الاقسام التسعة المنطقية لقاعدة البيانات
create schema if not exists iam;
create schema if not exists core;
create schema if not exists ops;
create schema if not exists inventory;
create schema if not exists billing;
create schema if not exists finance;
create schema if not exists audit;
create schema if not exists sync;
create schema if not exists reporting;
