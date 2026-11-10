-- canglin POC：PT10 脏行变体的源表（1 万行，其中 50 行 score 为非数值文本）
--
-- 与 src_users 的唯一差异：score 列改为 VARCHAR(64) 存文本。
-- 其中 id 能被 200 整除的 50 行（200,400,...,10000）score 写 'N/A'，
-- 其余 9950 行 score 存正常数值文本——这 50 行构成「类型错配」脏行。
USE canglin_src;

DROP TABLE IF EXISTS src_users_dirty;

CREATE TABLE src_users_dirty (
    id         BIGINT       NOT NULL,
    name       VARCHAR(64)  NOT NULL,
    score      VARCHAR(64)  NOT NULL,
    note       TEXT         NULL,
    created_at DATETIME     NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

DELIMITER $$
CREATE PROCEDURE seed_src_users_dirty()
BEGIN
    DECLARE i INT DEFAULT 1;
    WHILE i <= 10000 DO
        INSERT INTO src_users_dirty (id, name, score, note, created_at)
        VALUES (
            i,
            CONCAT('user_', LPAD(i, 5, '0')),
            IF(MOD(i, 200) = 0, 'N/A', CAST(ROUND(RAND() * 100, 2) AS CHAR)),
            IF(MOD(i, 100) = 0, NULL, CONCAT('note for user_', i)),
            DATE_SUB(NOW(), INTERVAL i MINUTE)
        );
        SET i = i + 1;
    END WHILE;
END$$
DELIMITER ;

CALL seed_src_users_dirty();
DROP PROCEDURE seed_src_users_dirty;
