package com.tekartik.sqflite;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Queue;
import java.util.Set;

public class DatabaseWorkerPoolTest {

    private FakeDatabaseWorkerPool pool;
    private FakeDatabaseWorker worker1;
    private FakeDatabaseWorker worker2;
    private FakeDatabase database1;
    private FakeDatabase database2;

    @Before
    public void setUp() {
        pool = new FakeDatabaseWorkerPool("pool", 2, 0);
        pool.start();
        worker1 = pool.getWorker(0);
        worker2 = pool.getWorker(1);
        database1 = new FakeDatabase(1);
        database2 = new FakeDatabase(2);
    }

    @After
    public void tearDown() {
        pool.quit();
    }

    /**
     * Deterministic native scheduler model: B waits for SQLite while A needs
     * its transaction continuation. This does not simulate Android SQLite.
     */
    @Test
    public void productionDefaultAllowsOwnerToProgressWhileOtherConnectionWaits()
            throws Exception {
        java.lang.reflect.Field count = SqflitePlugin.class.getDeclaredField("THREAD_COUNT");
        count.setAccessible(true);
        FakeDatabaseWorkerPool production = new FakeDatabaseWorkerPool(
                "production", count.getInt(null), 0);
        production.start();
        try {
            FakeDatabase owner = new FakeDatabase(10);
            FakeDatabase waiter = new FakeDatabase(11);
            owner.inTransaction = true;
            production.post(new DatabaseTask(owner, () -> {}));
            FakeDatabaseWorker ownerWorker = production.workers.stream()
                    .filter(w -> !w.tasks.isEmpty()).findFirst().get();
            production.post(new DatabaseTask(waiter, () -> {}));
            ownerWorker.work();
            // Leave B's task unfinished, as if waiting for SQLite's lock.
            boolean[] committed = {false};
            production.post(new DatabaseTask(owner, () -> {
                owner.inTransaction = false;
                committed[0] = true;
            }));
            assertTrue("owner continuation must progress despite blocked connection",
                    !ownerWorker.tasks.isEmpty());
            ownerWorker.work();
            assertTrue(committed[0]);
        } finally {
            production.quit();
        }
    }

    @Test
    public void tasksOfOneDBRunFIFO() {
        // Arrange.
        DatabaseTask task1 = new DatabaseTask(database1, () -> {
        });
        DatabaseTask task2 = new DatabaseTask(database1, () -> {
        });
        DatabaseTask task3 = new DatabaseTask(database2, () -> {
        });


        // Act. Posting three tasks. The first two are belonging to the same database.
        pool.post(task1);
        pool.post(task2); // It should not be started until task1 is done.
        pool.post(task3);

        // Assert. Worker1 run task1. Worker2 skipped task2 and run task3.
        assertEquals(Arrays.asList(task1), new ArrayList<>(worker1.tasks));
        assertEquals(Arrays.asList(task3), new ArrayList<>(worker2.tasks));

        // Act. Worker1 and worker2 finished one task.
        worker1.work();
        worker2.work();

        // Assert. Worker1 run task2.
        assertEquals(Arrays.asList(task2), new ArrayList<>(worker1.tasks));
        assertEquals(Collections.emptyList(), new ArrayList<>(worker2.tasks));
    }

    @Test
    public void tasksOfOneTransactionRunByOneWorker() {
        // Arrange.
        DatabaseTask task1 = new DatabaseTask(database1, () -> {
        });
        database2.inTransaction = true;
        DatabaseTask task2 = new DatabaseTask(database2, () -> {
        });


        // Act. Posting two tasks.
        pool.post(task1);
        pool.post(task2);

        // Assert. Worker1 run task1. Worker2 run task2 in transaction.
        assertEquals(Arrays.asList(task1), new ArrayList<>(worker1.tasks));
        assertEquals(Arrays.asList(task2), new ArrayList<>(worker2.tasks));

        // Act. Worker1 and worker2 finished one task. Then post a new task in the same transaction.
        worker1.work();
        worker2.work();
        DatabaseTask task3 = new DatabaseTask(database2, () -> {
        });
        pool.post(task3);


        // Assert. Worker1 was skipped. Worker2 run task2.
        assertEquals(Collections.emptyList(), new ArrayList<>(worker1.tasks));
        assertEquals(Arrays.asList(task3), new ArrayList<>(worker2.tasks));
    }

    @Test
    public void tasksOfDiffTransactionsRunByTwoWorker() {
        // Arrange.
        DatabaseTask task1 = new DatabaseTask(database1, () -> {
        });
        DatabaseTask task2 = new DatabaseTask(database2, () -> {
        });

        // Act. Posting two tasks.
        pool.post(task1);
        pool.post(task2);

        // Assert. Worker1 run task1. Worker2 run task2.
        assertEquals(Arrays.asList(task1), new ArrayList<>(worker1.tasks));
        assertEquals(Arrays.asList(task2), new ArrayList<>(worker2.tasks));

        // Act. Worker1 and worker2 finished one task. Then post a new task.
        worker1.work();
        worker2.work();
        DatabaseTask task3 = new DatabaseTask(database2, () -> {
        });
        pool.post(task3);


        // Assert. Task3 is not in transaction. Just find the first available worker (worker1)
        // to run task2.
        assertEquals(Arrays.asList(task3), new ArrayList<>(worker1.tasks));
        assertEquals(Collections.emptyList(), new ArrayList<>(worker2.tasks));
    }
}

class FakeDatabase implements DatabaseDelegate {

    final int databaseId;
    boolean inTransaction;

    FakeDatabase(int databaseId) {
        this.databaseId = databaseId;
    }

    @Override
    public int getDatabaseId() {
        return databaseId;
    }

    @Override
    public boolean isInTransaction() {
        return inTransaction;
    }
}

class FakeDatabaseWorker extends DatabaseWorker {

    Queue<DatabaseTask> tasks = new ArrayDeque<>();

    FakeDatabaseWorker(String name, int priority) {
        super(name, priority);
    }

    @Override
    void start(Runnable onIdle) {
        this.onIdle = onIdle;
    }

    @Override
    void quit() {
    }

    @Override
    void postTask(final DatabaseTask task) {
        tasks.add(task);
    }

    void work() {
        DatabaseTask task = tasks.remove();
        super.work(task);
    }
}

class FakeDatabaseWorkerPool extends DatabaseWorkerPoolImpl {

    final Set<FakeDatabaseWorker> workers = new HashSet<>();

    FakeDatabaseWorkerPool(String name, int numberOfWorkers, int priority) {
        super(name, numberOfWorkers, priority);
    }

    @Override
    protected DatabaseWorker createWorker(String name, int priority) {
        FakeDatabaseWorker worker = new FakeDatabaseWorker(name, priority);
        workers.add(worker);
        return worker;
    }

    FakeDatabaseWorker getWorker(int idx) {
        return new ArrayList<>(workers).get(idx);
    }
}
