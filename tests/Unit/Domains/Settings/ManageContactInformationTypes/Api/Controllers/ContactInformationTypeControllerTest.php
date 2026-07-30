<?php

namespace Tests\Unit\Domains\Settings\ManageContactInformationTypes\Api\Controllers;

use App\Models\ContactInformationType;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactInformationTypeControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_gets_a_list_of_contact_information_types(): void
    {
        $user = $this->createUser(['read']);

        $type = ContactInformationType::factory()->create([
            'account_id' => $user->account_id,
            'name' => 'Email',
            'type' => 'email',
        ]);

        // a type in another account must not appear
        ContactInformationType::factory()->create();

        $response = $this->get('/api/contactInformationTypes');

        $response->assertStatus(200);
        $response->assertJsonCount(1, 'data');
        $response->assertJsonPath('data.0.id', $type->id);
        $response->assertJsonPath('data.0.type', 'email');
    }
}
