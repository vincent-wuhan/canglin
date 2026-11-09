-- canglin POC：MySQL 8.4 源库初始化
-- 建源表 src_users 并用存储过程灌入 1 万行（note 每 100 行一个 NULL）
USE canglin_src;

CREATE TABLE src_users (
    id         BIGINT       NOT NULL,
    name       VARCHAR(64)  NOT NULL,
    score      DOUBLE       NULL,
    note       TEXT         NULL,
    created_at DATETIME     NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

DELIMITER $$
CREATE PROCEDURE seed_src_users()
BEGIN
    DECLARE i INT DEFAULT 1;
    WHILE i <= 10000 DO
        INSERT INTO src_users (id, name, score, note, created_at)
        VALUES (
            i,
            CONCAT('user_', LPAD(i, 5, '0')),
            ROUND(RAND() * 100, 2),
            IF(MOD(i, 100) = 0, NULL, CONCAT('note for user_', i)),
            DATE_SUB(NOW(), INTERVAL i MINUTE)
        );
        SET i = i + 1;
    END WHILE;
END$$
DELIMITER ;

CALL seed_src_users();
DROP PROCEDURE seed_src_users;
