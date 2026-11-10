-- canglin POC：PT10 脏行变体的目标表（列集合与 src_users_dirty 对齐）
--
-- 与 dst_users 的差异只有一处：score 收紧为 NOT NULL，
-- 用来验证「NULL 进 NOT NULL 列」与「文本解析不出数值」两条脏行判定在本变体里不叠加。
DROP TABLE IF EXISTS dst_users_dirty;

CREATE TABLE dst_users_dirty (
    id         BIGINT           NOT NULL,
    name       VARCHAR(64)      NOT NULL,
    score      DOUBLE PRECISION NOT NULL,
    note       TEXT             NULL,
    created_at TIMESTAMP        NOT NULL,
    CONSTRAINT dst_users_dirty_pkey PRIMARY KEY (id)
);
