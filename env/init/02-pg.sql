-- canglin POC：PostgreSQL 16 目标库初始化（空目标表 dst_users，列结构与 src_users 对齐）
CREATE TABLE dst_users (
    id         BIGINT           NOT NULL,
    name       VARCHAR(64)      NOT NULL,
    score      DOUBLE PRECISION NULL,
    note       TEXT             NULL,
    created_at TIMESTAMP        NOT NULL,
    CONSTRAINT dst_users_pkey PRIMARY KEY (id)
);
